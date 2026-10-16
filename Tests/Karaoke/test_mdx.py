from pathlib import Path
from types import SimpleNamespace
import json
import sys
import tempfile
import unittest
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Resources/Karaoke'))
from mdx import MDXSpectrum, predict_primary, read_parameters, uvr_hash, validate_session

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
