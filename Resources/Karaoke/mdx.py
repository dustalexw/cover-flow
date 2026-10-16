"""Local UVR MDX ONNX inference; stereo complex spectra and disk-backed overlap-add.

Parameter/hash conventions: see MDX-SOURCES.txt. Only vocal/instrumental models
are accepted; the complementary stem is the original mix minus the primary.
"""
import hashlib
import json
from pathlib import Path
import tempfile

import numpy as np
import soundfile as sf
import torch


def uvr_hash(path):
    with open(path, 'rb') as file:
        file.seek(max(0, Path(path).stat().st_size - 10_240_000))
        return hashlib.md5(file.read()).hexdigest()


def read_parameters(path, checkpoint):
    with open(path, encoding='utf-8-sig') as file:
        data = json.load(file)
    if not isinstance(data, dict):
        raise ValueError('MDX parameters must be a JSON object.')
    parameters = data if 'mdx_dim_f_set' in data else data.get(uvr_hash(checkpoint))
    if not isinstance(parameters, dict):
        raise ValueError('Unknown MDX model. Add its matching UVR JSON parameter file.')
    parameters = dict(parameters)
    if parameters.get('primary_stem') not in ('Vocals', 'Instrumental'):
        raise ValueError('Choose a vocal/instrumental MDX model; drum, bass and multi-stem models are not supported.')
    for key in ('mdx_dim_f_set', 'mdx_dim_t_set', 'mdx_n_fft_scale_set'):
        value = parameters.get(key)
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError('MDX dimensions must be integers from the matching UVR parameters.')
    n_fft, dim_f, exponent = (parameters[k] for k in ('mdx_n_fft_scale_set', 'mdx_dim_f_set', 'mdx_dim_t_set'))
    if not (2048 <= n_fft <= 32768 and n_fft % 2 == 0 and 1 <= dim_f <= n_fft // 2 + 1 and 4 <= exponent <= 10):
        raise ValueError('Unsupported MDX spectral dimensions.')
    if 1024 * (2 ** exponent - 1) <= n_fft:
        raise ValueError('MDX time window is too short for its FFT.')
    gain = parameters.get('compensate')
    if isinstance(gain, bool) or not isinstance(gain, (float, int)) or not np.isfinite(gain) or not 0 < gain <= 4:
        raise ValueError('MDX compensation must be a finite value between 0 and 4.')
    return parameters


class MDXSpectrum:
    def __init__(self, n_fft, dim_f):
        self.n_fft, self.dim_f = n_fft, dim_f
        self.window = torch.hann_window(n_fft)

    def encode(self, audio):
        # Four planes: left real/imaginary, then right real/imaginary.
        transformed = torch.stft(audio.reshape(-1, audio.shape[-1]), n_fft=self.n_fft,
            hop_length=1024, window=self.window, center=True, return_complex=True)
        planes = torch.view_as_real(transformed).permute(0, 3, 1, 2)
        return planes.reshape(1, 4, self.n_fft // 2 + 1, -1)[:, :, :self.dim_f].contiguous()

    def decode(self, spectrum, frames):
        bins = self.n_fft // 2 + 1
        padded = torch.nn.functional.pad(torch.from_numpy(np.ascontiguousarray(spectrum)), (0, 0, 0, bins - self.dim_f))
        planes = padded.reshape(2, 2, bins, -1).permute(0, 2, 3, 1).contiguous()
        return torch.istft(torch.view_as_complex(planes), n_fft=self.n_fft, hop_length=1024,
            window=self.window, center=True, length=frames).numpy()


def validate_session(session, parameters):
    inputs, outputs = session.get_inputs(), session.get_outputs()
    expected = [4, parameters['mdx_dim_f_set'], 2 ** parameters['mdx_dim_t_set']]
    if len(inputs) != 1 or len(outputs) != 1:
        raise ValueError('This ONNX graph is not a supported single-input/single-output UVR MDX model.')
    for value in (inputs[0], outputs[0]):
        if value.type != 'tensor(float)' or len(value.shape) != 4:
            raise ValueError('MDX models must use four-dimensional float32 spectra.')
        if isinstance(value.shape[0], int) and value.shape[0] != 1:
            raise ValueError('This MDX model requires an unsupported fixed batch size.')
        if any(isinstance(actual, int) and actual != wanted for actual, wanted in zip(value.shape[1:], expected)):
            raise ValueError('The ONNX graph does not match its UVR frequency/time settings.')
    return inputs[0].name


def predict_primary(audio, session, parameters, scratch, notify, denoise=True):
    """Run fixed-size MDX blocks with 50% overlap; retain every original frame."""
    frames = audio.shape[1]
    chunk = 1024 * (2 ** parameters['mdx_dim_t_set'] - 1)
    trim = parameters['mdx_n_fft_scale_set'] // 2
    generated = chunk - trim * 2
    tail = generated + trim - frames % generated
    total = frames + trim + tail
    step = chunk // 2
    starts = range(0, frames + trim, step)
    result = np.memmap(Path(scratch) / 'primary.pcm', mode='w+', dtype=np.float32, shape=(2, total))
    counter = np.memmap(Path(scratch) / 'weight.pcm', mode='w+', dtype=np.float32, shape=(total,))
    result[:] = 0; counter[:] = 0
    spectral = MDXSpectrum(parameters['mdx_n_fft_scale_set'], parameters['mdx_dim_f_set'])
    input_name = validate_session(session, parameters)
    with torch.inference_mode():
        for index, start in enumerate(starts):
            length = min(chunk, total - start)
            block = np.zeros((2, chunk), dtype=np.float32)
            low, high = max(start, trim), min(start + length, trim + frames)
            if high > low:
                block[:, low - start:high - start] = audio[:, low - trim:high - trim]
            spectrum = spectral.encode(torch.from_numpy(block)).numpy()
            spectrum[:, :, :3, :] = 0
            positive = session.run(None, {input_name: spectrum})[0]
            prediction = (positive - session.run(None, {input_name: -spectrum})[0]) * .5 if denoise else positive
            if prediction.shape != spectrum.shape or not np.isfinite(prediction).all():
                raise ValueError('The MDX model returned invalid spectra.')
            wave = spectral.decode(prediction, chunk)
            if wave.shape != block.shape or not np.isfinite(wave).all():
                raise ValueError('The MDX model returned invalid audio.')
            weight = np.hanning(length).astype(np.float32) if length > 2 else np.ones(length, dtype=np.float32)
            result[:, start:start + length] += wave[:, :length] * weight
            counter[start:start + length] += weight
            notify('Separating with UVR MDX on CPU', (index + 1) / len(starts), device='cpu')
    return result, counter, trim


def separate_mdx(checkpoint, config_path, input_path, output_dir, notify):
    import onnxruntime as ort
    ort.disable_telemetry_events()
    parameters = read_parameters(config_path, checkpoint)
    notify('Loading UVR MDX model on CPU', 0, device='cpu')
    options = ort.SessionOptions()
    options.intra_op_num_threads = min(4, __import__('os').cpu_count() or 1)
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(checkpoint), sess_options=options, providers=['CPUExecutionProvider'])
    torch.set_num_threads(min(4, __import__('os').cpu_count() or 1))
    output = Path(output_dir); output.mkdir(parents=True, exist_ok=True)
    with sf.SoundFile(input_path) as source, tempfile.TemporaryDirectory(prefix='.mdx-', dir=output) as scratch:
        if source.samplerate != 44100 or source.channels != 2 or source.frames < 1:
            raise ValueError('The prepared audio must be stereo at 44.1 kHz.')
        frames = source.frames
        audio = np.memmap(Path(scratch) / 'input.pcm', mode='w+', dtype=np.float32, shape=(2, frames))
        for start in range(0, frames, 262144):
            block = source.read(min(262144, frames - start), dtype='float32', always_2d=True)
            if not np.isfinite(block).all(): raise ValueError('The source contains invalid audio samples.')
            audio[:, start:start + len(block)] = block.T
        result, counter, trim = predict_primary(audio, session, parameters, scratch, notify)
        def stems_at(start, end):
            divisor = np.asarray(counter[trim + start:trim + end])
            if np.any(divisor <= 0): raise ValueError('Some MDX audio frames were not processed.')
            primary = np.asarray(result[:, trim + start:trim + end]) / divisor * parameters['compensate']
            complement = np.asarray(audio[:, start:end]) - primary
            return (primary, complement) if parameters['primary_stem'] == 'Vocals' else (complement, primary)
        peak = 0.0
        for start in range(0, frames, 262144):
            for stem in stems_at(start, min(frames, start + 262144)):
                if not np.isfinite(stem).all(): raise ValueError('The MDX model produced non-finite audio.')
                peak = max(peak, float(np.abs(stem).max()))
        gain = min(1.0, .98 / max(.98, peak))
        notify('Saving karaoke audio', 1, device='cpu')
        with sf.SoundFile(output / 'vocals.wav', 'w', samplerate=44100, channels=2, subtype='FLOAT') as vocals, \
             sf.SoundFile(output / 'instrumental.wav', 'w', samplerate=44100, channels=2, subtype='FLOAT') as instrumental:
            for start in range(0, frames, 262144):
                voice, music = stems_at(start, min(frames, start + 262144))
                vocals.write(voice.T * gain); instrumental.write(music.T * gain)
        del result, counter, audio
    return dict(frames=frames, sample_rate=44100, device='cpu', gain=gain)
