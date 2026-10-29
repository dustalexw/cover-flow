#!/usr/bin/env python3
"""Bundle both runnable Xcode projects with sources, resources and native runtime."""
import argparse
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='Folder for the prepared project folder and ZIP')
    args = parser.parse_args()
    subprocess.run(['bash', str(ROOT / 'scripts/fetch-ipad-runtime.sh')], check=True)
    subprocess.run(['python3', str(ROOT / 'scripts/make-ipad-project.py')], check=True)
    spec = importlib.util.spec_from_file_location('mobile_projects', ROOT / 'scripts/make-ipad-project.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = 'Cover-Flow-iOS-Xcode-Projects-1.2.0'
    stage = output / name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    paths = ['iPad/Sources', 'iPad/Core', 'iPad/Native', 'iPad/Resources', 'iPad/Vendor',
             'iPad/CoverFlow-Bridging-Header.h', 'iPad/Info.plist', 'iPad/README.md',
             'iPad/CoverFlow-iPad.xcodeproj', 'iPhone/Info.plist', 'iPhone/README.md',
             'iPhone/CoverFlow-iPhone.xcodeproj', 'Resources/AppIcon-1024.png',
             'Resources/Karaoke/mdx-model-data.json', 'Resources/Karaoke/MDX-SOURCES.txt',
             'build-ios.command', 'build-ipad.command', 'scripts/make-ipad-project.py',
             'scripts/fetch-ipad-runtime.sh', 'scripts/package-ios-projects.py']
    paths += ['Sources/CoverFlow/' + path for path in module.SHARED]
    paths += ['Sources/CoverFlow/Visualizer/Shaders/Visualizer.metal']
    for relative in paths:
        source, destination = ROOT / relative, stage / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination, symlinks=True,
                            ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate', '.DS_Store'))
        else:
            shutil.copy2(source, destination)
    (stage / 'START HERE.md').write_text('''# Cover Flow: ready-to-run Xcode projects

1. Open `iPhone/CoverFlow-iPhone.xcodeproj` or `iPad/CoverFlow-iPad.xcodeproj`.
2. Choose the matching CoverFlowiPhone or CoverFlowiPad scheme and a simulator/device.
3. For a physical device, select your Apple Developer team in Signing & Capabilities.
4. Press Run (Command-R).

Requires Xcode 16.4+ and iOS/iPadOS 17+. The projects, shared sources, artwork,
licenses and native ONNX Runtime are included. No dependency download is needed.
Keep the entire folder together; do not move the project file on its own.

Device builds made without a signing team are unsigned. A ZIP or unsigned app
cannot be installed directly on an iPhone/iPad; Xcode signs it using your account.
Model weights are user-supplied. See iPad/README.md for native karaoke support.
''')
    # Fail packaging if a generated source/resource still points outside the bundle
    # or is missing. Frameworks under SDKROOT are supplied by Xcode.
    import re
    for device in ['iPad', 'iPhone']:
        project = stage / device / ('CoverFlow-' + device + '.xcodeproj/project.pbxproj')
        for quoted in re.findall(r'path = ("(?:[^"\\]|\\.)*"); sourceTree = SOURCE_ROOT;', project.read_text()):
            import json
            path = (project.parent.parent / json.loads(quoted)).resolve()
            assert path.is_relative_to(stage.resolve()) and path.exists(), str(path)
    archive = output / (name + '.zip')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(stage), str(archive)], check=True)
    subprocess.run(['unzip', '-tq', str(archive)], check=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / (name + '-SHA256.txt')).write_text(digest + '  ' + archive.name + '\n')
    print(archive)


if __name__ == '__main__':
    main()
