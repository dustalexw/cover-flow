"""Demucs inference with pinned, verified weights and bounded disk-backed overlap-add."""
from contextlib import ExitStack
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request

import numpy as np
import soundfile as sf
import torch
import yaml

STEMS = {'drums', 'bass', 'other', 'vocals', 'guitar', 'piano'}


def digest(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def download(entry, cache, notify):
    """Only bundled catalog entries may specify remote files; verify before loading."""
    cache = Path(cache) / entry['revision']
    cache.mkdir(parents=True, exist_ok=True)
    paths = []
    for index, item in enumerate(entry['files']):
        path = cache / item['name']
        if path.is_file() and path.stat().st_size == item['size'] and digest(path) == item['sha256']:
            paths.append(path)
            continue
        url = f"https://huggingface.co/{entry['repo']}/resolve/{entry['revision']}/{item['name']}"
        temporary = path.with_suffix('.download')
        try:
            with urllib.request.urlopen(url, timeout=60) as response, open(temporary, 'wb') as output:
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > item['size']:
                        raise ValueError('The Demucs download has an unexpected size.')
                    output.write(block)
                    notify('Downloading ' + entry['title'], .15 * (index + size / item['size']) / len(entry['files']))
            if size != item['size'] or digest(temporary) != item['sha256']:
                raise ValueError('Demucs download verification failed. Try preparation again.')
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
        paths.append(path)
    return paths


def load_safe_model(path):
    """Safetensors only; never unpickle a downloaded model or import metadata code."""
    from demucs.demucs import Demucs
    from demucs.hdemucs import HDemucs
    from demucs.htdemucs import HTDemucs
    from safetensors import safe_open
    allowed = {'demucs.demucs.Demucs': Demucs, 'demucs.hdemucs.HDemucs': HDemucs, 'demucs.htdemucs.HTDemucs': HTDemucs}
    def decode(value):
        if isinstance(value, dict):
            if value.get('_type') == 'fraction':
                return Fraction(value['numerator'], value['denominator'])
            return {key: decode(item) for key, item in value.items()}
        if isinstance(value, list): return [decode(item) for item in value]
        return value
    with safe_open(str(path), framework='pt', device='cpu') as file:
        metadata = file.metadata() or {}
        if metadata.get('klass') not in allowed or 'structure' in metadata:
            raise ValueError('Choose an unquantized Demucs, HDemucs or HTDemucs safetensors model with architecture metadata.')
        model = allowed[metadata['klass']](*decode(json.loads(metadata['args'])), **decode(json.loads(metadata['kwargs'])))
        model.load_state_dict({key: file.get_tensor(key) for key in file.keys()}, strict=True)
    if model.samplerate != 44100 or model.audio_channels != 2 or not set(model.sources) <= STEMS or 'vocals' not in model.sources or len(set(model.sources)) != len(model.sources):
        raise ValueError('This Demucs model must use stereo 44.1 kHz audio and supported music stems.')
    return model.eval()


def overlap_add(audio, model, directory, device, notify):
    """Bound memory independently of song duration; all stems share identical windows."""
    from demucs.apply import apply_model
    frames = audio.shape[1]
    chunk = int(min(float(getattr(model, "max_allowed_segment", getattr(model, "segment", 6.0))), 6.0) * 44100)
    step = chunk // 2
    count = np.memmap(Path(directory) / 'weights.pcm', mode='w+', dtype='float32', shape=(frames,))
    output = np.memmap(Path(directory) / 'stems.pcm', mode='w+', dtype='float32', shape=(len(model.sources), 2, frames))
    count[:] = 0; output[:] = 0
    # Use whole-track mono statistics, as in the reference Demucs separator.
    total = squares = 0.0
    for start in range(0, frames, 262144):
        mono = np.asarray(audio[:, start:start + 262144]).mean(axis=0, dtype=np.float64)
        total += mono.sum(); squares += np.square(mono).sum()
    mean = total / frames
    std = max(1e-8, np.sqrt(max(0, squares / frames - mean * mean)))
    window = np.hanning(chunk).astype('float32')
    with torch.inference_mode():
        for start in range(0, frames, step):
            length = min(chunk, frames - start)
            part = np.zeros((2, chunk), dtype='float32')
            part[:, :length] = (np.asarray(audio[:, start:start + length]) - mean) / std
            tensor = torch.from_numpy(part)[None]
            try:
                prediction = apply_model(model, tensor, device=device, shifts=0, split=False)[0]
            except (RuntimeError, NotImplementedError):
                if device != 'mps': raise
                device = 'cpu'; model.to(device)
                notify('Separating stems on CPU', .15 + .8 * start / frames, device=device)
                prediction = apply_model(model, tensor, device=device, shifts=0, split=False)[0]
            prediction = prediction.detach().cpu().float().numpy()[:, :, :length] * std + mean / len(model.sources)
            if prediction.shape != (len(model.sources), 2, length) or not np.isfinite(prediction).all():
                raise ValueError('Demucs returned invalid stem audio.')
            weight = window[:length].copy()
            if start == 0: weight[:step] = 1
            if start + chunk >= frames: weight[max(0, length - step):] = 1
            output[:, :, start:start + length] += prediction * weight
            count[start:start + length] += weight
            notify('Separating ' + str(len(model.sources)) + ' stems', .15 + .8 * min(1, (start + step) / frames), device=device)
    return output, count, device


def separate_demucs(checkpoint, config_path, input_path, output_dir, notify, requested_device='auto'):
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    notify('Loading Demucs', 0)
    if Path(checkpoint).suffix == '.safetensors':
        paths = [Path(checkpoint)]; entry = None
    else:
        descriptor = json.loads(Path(config_path).read_text())
        catalog = json.loads(Path(__file__).with_name('demucs-models.json').read_text())
        entry = next((item for item in catalog if item['name'] == descriptor.get('name')), None)
        if entry is None: raise ValueError('Unknown Demucs model. Choose a model from the built-in catalog.')
        paths = download(entry, Path(output_dir).parent / 'DemucsModels', notify)
    models = [load_safe_model(path) for path in paths]
    if entry:
        from demucs.apply import BagOfModels
        bag = yaml.safe_load(entry['bag'])
        by_name = {path.stem: model for path, model in zip(paths, models)}
        model = BagOfModels([by_name[sig] for sig in bag['models']], bag.get('weights'))
        if list(model.sources) != entry['stems']: raise ValueError('The downloaded model has unexpected stems.')
    else: model = models[0]
    device = 'mps' if requested_device == 'auto' and torch.backends.mps.is_available() else requested_device
    if device == 'auto': device = 'cpu'
    if device not in ('cpu', 'mps'): raise ValueError('Demucs supports CPU or Apple GPU processing.')
    try: model.to(device)
    except (RuntimeError, NotImplementedError):
        if device != 'mps': raise
        device = 'cpu'; model.to(device)
    output_dir = Path(output_dir)
    with sf.SoundFile(input_path) as source, tempfile.TemporaryDirectory(prefix='.demucs-', dir=output_dir) as scratch:
        if source.samplerate != 44100 or source.channels != 2 or source.frames < 1:
            raise ValueError('Demucs needs stereo 44.1 kHz input.')
        frames = source.frames
        audio = np.memmap(Path(scratch) / 'input.pcm', mode='w+', dtype='float32', shape=(2, frames))
        for start in range(0, frames, 262144):
            block = source.read(min(262144, frames - start), dtype='float32', always_2d=True)
            if not np.isfinite(block).all(): raise ValueError('The source contains invalid samples.')
            audio[:, start:start + len(block)] = block.T
        result, counter, device = overlap_add(audio, model, scratch, device, notify)
        vocal_index = list(model.sources).index('vocals')
        def block_at(start):
            end = min(frames, start + 262144)
            denominator = np.asarray(counter[start:end])
            if np.any(denominator <= 0): raise ValueError('Demucs did not cover every frame.')
            stems = np.asarray(result[:, :, start:end]) / denominator
            instrumental = stems.sum(axis=0) - stems[vocal_index]
            return stems, instrumental
        peak = 0.98
        for start in range(0, frames, 262144):
            stems, instrumental = block_at(start)
            # One gain preserves relative balance; also leave headroom for the unity mix.
            peak = max(peak, float(np.abs(stems).max()), float(np.abs(instrumental).max()), float(np.abs(stems.sum(axis=0)).max()))
        gain = .98 / peak
        notify('Saving all stems', .96, device=device)
        with ExitStack() as stack:
            files = [stack.enter_context(sf.SoundFile(output_dir / (stem + '.wav'), 'w', samplerate=44100, channels=2, subtype='FLOAT')) for stem in model.sources]
            instrumental_file = stack.enter_context(sf.SoundFile(output_dir / 'instrumental.wav', 'w', samplerate=44100, channels=2, subtype='FLOAT'))
            for start in range(0, frames, 262144):
                stems, instrumental = block_at(start)
                for file, stem in zip(files, stems): file.write((stem * gain).T)
                instrumental_file.write((instrumental * gain).T)
        del result, counter, audio
    model_hash = hashlib.sha256(''.join(digest(path) for path in paths).encode()).hexdigest()
    return dict(frames=frames, sample_rate=44100, model_sha256=model_hash, stems=list(model.sources), device=device, gain=gain)
