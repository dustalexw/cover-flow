"""Overlap-add, edge lengths and safe configuration parsing; no model download."""
from pathlib import Path
import sys
import tempfile
import unittest
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Resources/Karaoke'))
from separate import overlap_add, read_config


class IdentityStems:
    def __call__(self, tensor):
        return torch.stack((tensor * .25, tensor * .75), dim=1)


class SeparationTests(unittest.TestCase):
    def test_overlap_add_retains_edges_and_exact_length(self):
        for frames in (37, 2048, 8192, 30001):
            with self.subTest(frames=frames), tempfile.TemporaryDirectory() as directory:
                audio = np.stack((np.sin(np.arange(frames) * .03), np.cos(np.arange(frames) * .04))).astype(np.float32)
                result, count, border, device = overlap_add(audio, IdentityStems(), 8192, 2, 'cpu', directory, notify=lambda *a, **k: None)
                denominator = count[border:border + frames]
                self.assertTrue((denominator > 0).all())
                stems = np.asarray(result[:, :, border:border + frames]) / denominator
                np.testing.assert_allclose(stems[0], audio * .25, atol=1e-7)
                np.testing.assert_allclose(stems[1], audio * .75, atol=1e-7)
                self.assertEqual(device, 'cpu')
                del result, count

    def test_python_object_yaml_tags_are_rejected(self):
        import yaml
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.yaml'
            path.write_text('model: !!python/object/apply:os.system ["echo should-not-run"]')
            with self.assertRaises(yaml.constructor.ConstructorError): read_config(path)

    def test_incompatible_stem_order_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.yaml'
            path.write_text('training:\n  instruments: [Instrumental, Vocals]')
            with self.assertRaises(ValueError): read_config(path)


if __name__ == '__main__':
    unittest.main()
