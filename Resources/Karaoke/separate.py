"""Offline Mel-Band RoFormer and UVR MDX inference. Progress is JSON-lines."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

os.environ.setdefault('PYTORCH_ENABLE_MPS_FALLBACK', '1')
import numpy as np
import soundfile as sf
import torch
import yaml
from models.bs_roformer.mel_band_roformer import MelBandRoformer


def emit(stage, progress=0, **extra):
    print(json.dumps({'stage': stage, 'progress': progress, **extra}), flush=True)


class ConfigLoader(yaml.SafeLoader):
    pass
ConfigLoader.add_constructor('tag:yaml.org,2002:python/tuple', lambda loader, node: tuple(loader.construct_sequence(node)))


def read_config(path):
    with open(path, encoding='utf-8-sig') as file:
        config = yaml.load(file, Loader=ConfigLoader)
    if not isinstance(config, dict) or config.get('training', {}).get('instruments') != ['Vocals', 'Instrumental']:
        raise ValueError('Choose a matching two-stem Mel-Band RoFormer configuration (Vocals, Instrumental).')
    if config.get('audio', {}).get('sample_rate') != 44100 or config.get('model', {}).get('num_stems') != 2 or not config['model'].get('stereo'):
        raise ValueError('The selected configuration must describe a stereo 44.1 kHz, two-stem Mel-Band RoFormer model.')
    return config


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def overlap_add(audio, model, chunk, overlap, device, directory, notify=emit):
    """Disk-backed overlap-add with reflected context and exact original length."""
    channels, frames = audio.shape
    if channels != 2 or frames < 1:
        raise ValueError('The input must contain stereo audio.')
    chunk = min(chunk, max(2048, frames))
    if overlap < 1 or overlap > 8 or chunk < 2048:
        raise ValueError('Invalid overlap or chunk settings.')
    step = max(1, chunk // overlap)
    border = chunk - step if frames > 2 * (chunk - step) else 0
    total = frames + border * 2
    result = np.memmap(Path(directory) / 'result.pcm', mode='w+', dtype=np.float32, shape=(2, channels, total))
    count = np.memmap(Path(directory) / 'count.pcm', mode='w+', dtype=np.float32, shape=(total,))
    result[:] = 0; count[:] = 0
    fade = chunk // 10
    window = np.ones(chunk, dtype=np.float32)
    window[:fade] = np.linspace(0, 1, fade)
    window[-fade:] = np.linspace(1, 0, fade)
    with torch.inference_mode():
        for start in range(0, total, step):
            length = min(chunk, total - start)
            indices = np.arange(start, start + length) - border
            if border:
                period = 2 * (frames - 1)
                indices %= period
                indices = np.minimum(indices, period - indices)
            part = np.asarray(audio[:, indices], dtype=np.float32)
            pad = chunk - length
            if pad:
                part = np.pad(part, ((0, 0), (0, pad)), mode='reflect' if length > chunk // 2 else 'constant')
            tensor = torch.from_numpy(np.ascontiguousarray(part))[None].to(device)
            try:
                prediction = model(tensor)
            except (RuntimeError, NotImplementedError) as error:
                if device != 'mps': raise
                # Unsupported spectral operations can still occur on some Macs.
                device = 'cpu'; model.to(device)
                notify('Separating on CPU', start / total, device=device)
                prediction = model(tensor.cpu())
            prediction = prediction[0].detach().cpu().float().numpy()
            if prediction.shape != (2, 2, chunk) or not np.isfinite(prediction).all():
                raise ValueError('The model returned invalid audio. Check that the checkpoint matches its configuration.')
            weight = window.copy()
            if start == 0: weight[:fade] = 1
            if start + step >= total: weight[-fade:] = 1
            result[:, :, start:start + length] += prediction[:, :, :length] * weight[:length]
            count[start:start + length] += weight[:length]
            notify('Separating vocals and instrumental', min(1, (start + step) / total), device=device)
    return result, count, border, device


def separate(checkpoint, config_path, input_path, output_dir, requested_device='auto'):
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    config = read_config(config_path)
    emit('Loading Mel-Band RoFormer', 0)
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    model = MelBandRoformer(**{**config['model'], 'match_input_audio_length': True})
    state = torch.load(checkpoint, map_location='cpu', weights_only=True)
    if isinstance(state, dict) and 'state_dict' in state:
        state = state['state_dict']
    model.load_state_dict(state, strict=True)
    del state
    model.eval()
    device = 'mps' if requested_device == 'auto' and torch.backends.mps.is_available() else requested_device
    if device == 'auto': device = 'cpu'
    if device not in ('cpu', 'mps'): raise ValueError('Unsupported processing device.')
    try:
        model.to(device)
    except (RuntimeError, NotImplementedError):
        if device != 'mps' or requested_device != 'auto': raise
        device = 'cpu'; model.to(device)
        emit('Loading model on CPU', 0, device=device)
    with sf.SoundFile(input_path) as source, tempfile.TemporaryDirectory(prefix='.processing-', dir=output) as scratch:
        if source.samplerate != 44100 or source.channels != 2 or source.frames < 1:
            raise ValueError('The prepared audio must be stereo at 44.1 kHz.')
        frames = source.frames
        audio = np.memmap(Path(scratch) / 'input.pcm', mode='w+', dtype=np.float32, shape=(2, frames))
        for start in range(0, frames, 262144):
            block = source.read(min(262144, frames - start), dtype='float32', always_2d=True)
            if not np.isfinite(block).all(): raise ValueError('The source contains invalid audio samples.')
            audio[:, start:start + len(block)] = block.T
        chunk = int(config.get('inference', {}).get('chunk_size', config['audio']['chunk_size']))
        overlap = int(config.get('inference', {}).get('num_overlap', 2))
        result, counter, border, device = overlap_add(audio, model, chunk, overlap, device, scratch)
        peak = 0.0
        def block_at(start, end):
            denominator = np.asarray(counter[border + start:border + end])
            if np.any(denominator <= 0): raise ValueError('Some audio frames were not processed.')
            return np.asarray(result[:, :, border + start:border + end]) / denominator
        for start in range(0, frames, 262144):
            peak = max(peak, float(np.abs(block_at(start, min(frames, start + 262144))).max()))
        gain = min(1.0, .98 / max(.98, peak))
        emit('Saving karaoke audio', 1, device=device)
        with sf.SoundFile(output / 'vocals.wav', 'w', samplerate=44100, channels=2, subtype='FLOAT') as vocals, \
             sf.SoundFile(output / 'instrumental.wav', 'w', samplerate=44100, channels=2, subtype='FLOAT') as instrumental:
            for start in range(0, frames, 262144):
                separated = block_at(start, min(frames, start + 262144)) * gain
                vocals.write(separated[0].T); instrumental.write(separated[1].T)
        # Close mappings before the scratch directory is removed.
        del result, counter, audio
    emit('Ready', 1, frames=frames, sample_rate=44100, device=device, model_sha256=file_hash(checkpoint), gain=gain)


def main():
    parser = argparse.ArgumentParser()
    for flag in ('checkpoint', 'config', 'input', 'output'):
        parser.add_argument('--' + flag, required=True)
    parser.add_argument('--backend', choices=('auto', 'mel-band-roformer', 'mdx'), default='auto')
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'coreml'), default='auto')
    args = parser.parse_args()
    try:
        backend = ('mdx' if Path(args.checkpoint).suffix.lower() == '.onnx' else 'mel-band-roformer') if args.backend == 'auto' else args.backend
        if backend == 'mdx':
            from mdx import separate_mdx
            result = separate_mdx(args.checkpoint, args.config, args.input, args.output, emit, args.device)
            emit('Ready', 1, model_sha256=file_hash(args.checkpoint), **result)
        else:
            separate(args.checkpoint, args.config, args.input, args.output, args.device)
    except KeyboardInterrupt:
        emit('Cancelled', 0); return 130
    except Exception as error:
        emit('Failed', 0, error=str(error)); return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
