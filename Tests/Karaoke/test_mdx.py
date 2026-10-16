from pathlib import Path
from types import SimpleNamespace
import json
import sys
import tempfile
import unittest
from unittest.mock import MagicMock
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Resources/Karaoke'))
from mdx import MDXSession, MDXSpectrum, predict_primary, read_parameters, uvr_hash, validate_session

PARAMETERS = dict(compensate=1.01, mdx_dim_f_set=1025, mdx_dim_t_set=4,
                  mdx_n_fft_scale_set=2048, primary_stem='Instrumental')


class IdentitySession:
    def get_inputs(self):
        return [SimpleNamespace(name='custom_input', type='tensor(float)', shape=['batch', 4, 1025, 16])]
    def get_outputs(self):
        return [SimpleNamespace(name='output', type='tensor(float)', shape=['batch', 4, 1025, 16])]
    def run(self, _, feed):
        return [feed['custom_input'].copy()]


class MDXTests(unittest.TestCase):
    def runtime(self, gpu=None, cpu=None, available=True):
        runtime = MagicMock()
        runtime.__version__ = 'test'
        runtime.get_available_providers.return_value = ['CoreMLExecutionProvider'] if available else []
        gpu, cpu = gpu or IdentitySession(), cpu or IdentitySession()
        gpu.get_providers = lambda: ['CoreMLExecutionProvider', 'CPUExecutionProvider']
        gpu.disable_fallback = lambda: None
        cpu.disable_fallback = lambda: None
        runtime.InferenceSession.side_effect = lambda *args, **kwargs: gpu if isinstance(kwargs['providers'][0], tuple) else cpu
        return runtime

    def test_gpu_conversion_uses_static_batch_and_content_specific_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'model.onnx'; model.write_bytes(b'original')
            runtime = self.runtime()
            session = MDXSession(runtime, model, PARAMETERS, Path(directory) / 'cache', lambda *a, **k: None)
            self.assertEqual(session.device, 'coreml')
            first = runtime.InferenceSession.call_args.kwargs['providers'][0][1]
            self.assertEqual(first['MLComputeUnits'], 'CPUAndGPU')
            self.assertEqual(first['RequireStaticInputShapes'], '1')
            self.assertEqual(first['ModelFormat'], 'MLProgram')
            runtime.SessionOptions.return_value.add_free_dimension_override_by_name.assert_any_call('batch_size', 1)
            model.write_bytes(b'replacement at the same path')
            MDXSession(runtime, model, PARAMETERS, Path(directory) / 'cache', lambda *a, **k: None)
            second = runtime.InferenceSession.call_args.kwargs['providers'][0][1]
            self.assertNotEqual(first['ModelCacheDirectory'], second['ModelCacheDirectory'])

    def test_cpu_mode_and_missing_gpu_provider_do_not_attempt_conversion(self):
        for mode, available in [('cpu', True), ('auto', False)]:
            runtime, progress = self.runtime(available=available), []
            session = MDXSession(runtime, 'no model read needed.onnx', PARAMETERS, '/unused',
                lambda stage, value, **kwargs: progress.append(kwargs['device']), mode)
            self.assertEqual(session.device, 'cpu')
            self.assertEqual(runtime.InferenceSession.call_args.kwargs['providers'], ['CPUExecutionProvider'])

    def test_gpu_load_failure_falls_back_and_keeps_cpu_errors_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'model.onnx'; model.write_bytes(b'original')
            runtime = self.runtime(); cpu = runtime.InferenceSession(None, providers=['CPUExecutionProvider'])
            runtime.InferenceSession.reset_mock()
            runtime.InferenceSession.side_effect = [RuntimeError('GPU compilation failed'), cpu]
            progress = []
            session = MDXSession(runtime, model, PARAMETERS, directory,
                lambda stage, value, **kwargs: progress.append(kwargs['device']))
            self.assertEqual(session.device, 'cpu'); self.assertIn('cpu', progress)
            runtime.InferenceSession.side_effect = RuntimeError('Invalid CPU model')
            with self.assertRaisesRegex(RuntimeError, 'Invalid CPU model'):
                MDXSession(runtime, model, PARAMETERS, directory, lambda *a, **k: None)

    def test_gpu_prediction_failure_retries_both_signs_on_cpu_once(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'model.onnx'; model.write_bytes(b'original')
            spectrum = np.ones((1, 4, 1025, 16), dtype=np.float32)
            for invalid_output in (False, True):
                gpu, cpu = IdentitySession(), IdentitySession()
                gpu.run = MagicMock(side_effect=[[spectrum * 100], [np.full_like(spectrum, np.nan)]] if invalid_output else [[spectrum * 100], RuntimeError('GPU unavailable')])
                cpu.run = MagicMock(side_effect=lambda _, feed: [next(iter(feed.values())).copy()])
                runtime = self.runtime(gpu, cpu); events = []
                session = MDXSession(runtime, model, PARAMETERS, directory,
                    lambda stage, value, **kwargs: events.append((value, kwargs['device'])))
                np.testing.assert_array_equal(session.predict(spectrum, 'custom_input', True, .5), spectrum)
                self.assertEqual(session.device, 'cpu'); self.assertEqual(events[-1], (.5, 'cpu'))
                self.assertEqual(cpu.run.call_count, 2)
                session.predict(spectrum, 'custom_input', True, .75)
                self.assertEqual(gpu.run.call_count, 2)  # No repeated GPU failures.

    def test_stereo_complex_packing_round_trip_preserves_channels_and_edges(self):
        rng = np.random.default_rng(10)
        audio = rng.normal(0, .05, (2, 15360)).astype(np.float32)
        spectral = MDXSpectrum(2048, 1025)
        spectrum = spectral.encode(torch.from_numpy(audio))
        self.assertEqual(tuple(spectrum.shape), (1, 4, 1025, 16))
        np.testing.assert_allclose(spectral.decode(spectrum.numpy(), audio.shape[1]), audio, atol=1e-6)

    def test_overlap_add_handles_short_long_and_silent_audio_without_losing_edges(self):
        for frames in (1, 37, 15360, 30001):
            for silence in (True, False):
                with self.subTest(frames=frames, silence=silence), tempfile.TemporaryDirectory() as directory:
                    audio = np.zeros((2, frames), dtype=np.float32)
                    if not silence: audio[0, 0] = .5; audio[1, -1] = .5
                    progress = []
                    result, weights, trim = predict_primary(audio, IdentitySession(), PARAMETERS, directory,
                        lambda stage, value, **kwargs: progress.append(value))
                    count = np.asarray(weights[trim:trim + frames])
                    self.assertTrue((count > 0).all())
                    restored = np.asarray(result[:, trim:trim + frames]) / count
                    self.assertEqual(restored.shape, audio.shape)
                    self.assertTrue(np.isfinite(restored).all())
                    if silence: self.assertEqual(float(np.abs(restored).max()), 0)
                    else:
                        self.assertGreater(restored[0, 0], .4)
                        self.assertGreater(restored[1, -1], .4)
                    self.assertEqual(progress[-1], 1)
                    del result, weights

    def test_parameter_catalog_lookup_and_custom_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            model, config = Path(directory) / 'renamed.onnx', Path(directory) / 'parameters.json'
            model.write_bytes(b'fixture')
            config.write_text(json.dumps({uvr_hash(model): PARAMETERS}))
            self.assertEqual(read_parameters(config, model), PARAMETERS)
            config.write_text(json.dumps(PARAMETERS))
            self.assertEqual(read_parameters(config, model), PARAMETERS)
            config.write_text('{}')
            with self.assertRaises(ValueError): read_parameters(config, model)
            for changed in ({'primary_stem':'Bass'}, {'mdx_dim_t_set':True}, {'mdx_n_fft_scale_set':1},
                            {'mdx_dim_f_set':100000}, {'compensate':float('nan')}):
                config.write_text(json.dumps({**PARAMETERS, **changed}))
                with self.assertRaises(ValueError): read_parameters(config, model)

    def test_wrong_model_graph_does_not_run_with_guessed_settings(self):
        self.assertEqual(validate_session(IdentitySession(), PARAMETERS), 'custom_input')
        with self.assertRaises(ValueError):
            validate_session(IdentitySession(), {**PARAMETERS, 'mdx_dim_f_set':512})
        with self.assertRaises(ValueError):
            validate_session(SimpleNamespace(get_inputs=lambda:[], get_outputs=lambda:[]), PARAMETERS)


if __name__ == '__main__': unittest.main()
