"""All-stem overlap, exact lengths and safe model loading."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import numpy as np
import torch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Resources/Karaoke'))
from demucs_backend import overlap_add, load_safe_model


class SixStems:
    sources = ['drums', 'bass', 'other', 'vocals', 'guitar', 'piano']
    segment = .1


class DemucsTests(unittest.TestCase):
    def test_six_stems_reconstruct_edges_short_and_long_tracks(self):
        def apply(model, tensor, **kwargs):
            return torch.stack([tensor * (i + 1) / 21 for i in range(6)], dim=1)
        for frames in [1, 37, 4410, 12001]:
            with self.subTest(frames=frames), tempfile.TemporaryDirectory() as directory, patch('demucs.apply.apply_model', side_effect=apply):
                audio = np.stack([np.sin(np.arange(frames) * .03) + .1, np.cos(np.arange(frames) * .07) + .1]).astype('float32')
                result, count, device = overlap_add(audio, SixStems(), directory, 'cpu', lambda *a, **k: None)
                self.assertTrue((count > 0).all())
                separated = np.asarray(result) / count
                self.assertEqual(separated.shape, (6, 2, frames))
                np.testing.assert_allclose(separated.sum(axis=0), audio, atol=1e-6)
                self.assertEqual(device, 'cpu')
                del result, count

    def test_metadata_cannot_import_arbitrary_classes(self):
        from safetensors.torch import save_file
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.safetensors'
            save_file({'weight': torch.zeros(1)}, str(path), metadata={'klass': 'os.system', 'args': '[]', 'kwargs': '{}'})
            with self.assertRaisesRegex(ValueError, 'unquantized Demucs'):
                load_safe_model(path)


if __name__ == '__main__': unittest.main()
