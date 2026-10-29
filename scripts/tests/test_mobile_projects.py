import importlib.util
from pathlib import Path
import tempfile
import unittest

GENERATOR = Path(__file__).resolve().parents[1] / 'make-ipad-project.py'


class MobileProjectTests(unittest.TestCase):
    def test_device_families_paths_and_independent_signing_survive_regeneration(self):
        spec = importlib.util.spec_from_file_location('projects', GENERATOR)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            module.ROOT = Path(directory)
            for device, family in [('iPad', '2'), ('iPhone', '1')]:
                module.generate(device)
                project = module.ROOT / device / ('CoverFlow-' + device + '.xcodeproj/project.pbxproj')
                original = project.read_text()
                self.assertIn('TARGETED_DEVICE_FAMILY = "' + family + '"', original)
                self.assertNotIn(directory, original)
                custom = 'dev.example.' + device.lower()
                text = original.replace('DEVELOPMENT_TEAM = ""', 'DEVELOPMENT_TEAM = "ABCDEFGHIJ"')
                text = text.replace('app.coverflow.player.' + device.lower(), custom)
                project.write_text(text)
                module.generate(device)
                regenerated = project.read_text()
                self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "' + custom + '"', regenerated)
                self.assertIn('DEVELOPMENT_TEAM = "ABCDEFGHIJ"', regenerated)
                if device == 'iPhone':
                    self.assertIn('../iPad/Vendor/onnxruntime.xcframework', regenerated)
                    self.assertIn('../iPad/Native/include', regenerated)


if __name__ == '__main__':
    unittest.main()
