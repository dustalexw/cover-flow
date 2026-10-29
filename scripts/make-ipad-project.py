#!/usr/bin/env python3
"""Generate ready-to-open iPad and iPhone projects sharing one mobile codebase."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
SHARED = ['Model/Models.swift', 'Playback/PlayerEngine.swift', 'Playback/GaplessAudioPlayer.swift',
          'Playback/PCMDecoder.swift', 'Playback/PlaybackOrder.swift', 'Visualizer/VisualizerAudioBuffer.swift',
          'Visualizer/VisualizerSignal.swift', 'Visualizer/NativeVisualizerSurface.swift',
          'Downloads/MusicLookupClient.swift', 'Downloads/MusicDownloadViews.swift',
          'Library/MetadataReader.swift', 'Library/OggOpus.swift', 'Lyrics/LyricsDocument.swift',
          'Lyrics/LyricsStore.swift', 'Scrobbling/LastFmAPI.swift', 'Scrobbling/LastFmKeychain.swift',
          'Scrobbling/LastFmScrobbler.swift', 'Scrobbling/ScrobbleProgress.swift', 'Views/ScrollingTrackTitle.swift']


def generate(device):
    folder = ROOT / device
    folder.mkdir(exist_ok=True)
    name = 'CoverFlow' + device
    project_name = 'CoverFlow-' + device + '.xcodeproj'
    project_dir = folder / project_name
    previous = (project_dir / 'project.pbxproj').read_text() if (project_dir / 'project.pbxproj').exists() else ''
    team_match = re.search(r'DEVELOPMENT_TEAM\s*=\s*"?([A-Z0-9]{10})"?;', previous)
    team = os.environ.get('COVERFLOW_APPLE_TEAM') or (team_match.group(1) if team_match else '')
    bundle_match = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([A-Za-z0-9.-]+)"?;', previous)
    bundle = bundle_match.group(1) if bundle_match else 'app.coverflow.player.' + device.lower()
    prefix = '' if device == 'iPad' else '../iPad/'
    sources = [os.path.relpath(p, folder) for part in ['Sources', 'Core']
               for p in sorted((ROOT / 'iPad' / part).glob('*.swift'))]
    sources += [prefix + 'Native/CFMDXRuntime.mm'] + ['../Sources/CoverFlow/' + p for p in SHARED]
    resources = ['../Sources/CoverFlow/Visualizer/Shaders/Visualizer.metal']
    resources += [prefix + p for p in ['Resources/Assets.xcassets', 'Resources/ONNX-Runtime-LICENSE.txt',
                  'Resources/ONNX-Runtime-ThirdPartyNotices.txt', 'Resources/PrivacyInfo.xcprivacy']]
    resources += ['../Resources/Karaoke/mdx-model-data.json', '../Resources/Karaoke/MDX-SOURCES.txt']
    objects = {}

    def uid(value):
        return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

    def add(key, value):
        objects[uid(key)] = value
        return uid(key)

    def q(value):
        return json.dumps(str(value))

    files, builds, resource_builds, framework_builds = [], [], [], []
    for path in sources + resources:
        kind = ('sourcecode.cpp.objcpp' if path.endswith('.mm') else 'sourcecode.swift' if path.endswith('.swift')
                else 'folder.assetcatalog' if path.endswith('.xcassets') else 'text.json' if path.endswith('.json') else 'text')
        ref = add('file:' + path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
        files.append(ref)
        build = add('build:' + path, f'isa = PBXBuildFile; fileRef = {ref};')
        (builds if path in sources else resource_builds).append(build)
    runtime = prefix + 'Vendor/onnxruntime.xcframework'
    ref = add('file:' + runtime, f'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = {q(runtime)}; sourceTree = SOURCE_ROOT;')
    files.append(ref)
    framework_builds.append(add('build:' + runtime, f'isa = PBXBuildFile; fileRef = {ref};'))
    for framework in ['CoreML', 'Accelerate', 'Metal', 'AVFoundation', 'MediaPlayer', 'Security', 'AudioToolbox', 'UIKit']:
        ref = add('system:' + framework, f'isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {framework}.framework; path = System/Library/Frameworks/{framework}.framework; sourceTree = SDKROOT;')
        files.append(ref)
        framework_builds.append(add('link:' + framework, f'isa = PBXBuildFile; fileRef = {ref};'))
    product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Cover Flow.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    products = add('products', f'isa = PBXGroup; children = ({product}); name = Products; sourceTree = "<group>";')
    main = add('main', f'isa = PBXGroup; children = ({",".join(files + [products])}); sourceTree = "<group>";')
    phases = []
    for key, kind, ids in [('sources', 'Sources', builds), ('frameworks', 'Frameworks', framework_builds), ('resources', 'Resources', resource_builds)]:
        phases.append(add(key, f'isa = PBX{kind}BuildPhase; buildActionMask = 2147483647; files = ({",".join(ids)}); runOnlyForDeploymentPostprocessing = 0;'))
    project_configs, target_configs = [], []
    for mode in ['Debug', 'Release']:
        values = dict(IPHONEOS_DEPLOYMENT_TARGET='17.0', SDKROOT='iphoneos', SWIFT_VERSION='5.0',
                      CLANG_CXX_LANGUAGE_STANDARD='c++17', CLANG_ENABLE_MODULES='YES', ENABLE_USER_SCRIPT_SANDBOXING='YES',
                      SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                      DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                      SWIFT_COMPILATION_MODE='singlefile' if mode == 'Debug' else 'wholemodule',
                      SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode == 'Debug' else '')
        target = dict(PRODUCT_BUNDLE_IDENTIFIER=bundle, PRODUCT_NAME='Cover Flow', PRODUCT_MODULE_NAME=name,
                      INFOPLIST_FILE='Info.plist', CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM=team,
                      TARGETED_DEVICE_FAMILY='2' if device == 'iPad' else '1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
                      SUPPORTS_MACCATALYST='NO', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                      ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor',
                      SWIFT_OBJC_BRIDGING_HEADER='$(SRCROOT)/' + prefix + 'CoverFlow-Bridging-Header.h',
                      HEADER_SEARCH_PATHS='$(SRCROOT)/' + prefix + 'Native/include',
                      LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks', OTHER_LDFLAGS='$(inherited) -ObjC',
                      ENABLE_BITCODE='NO', ENABLE_TESTABILITY='YES' if mode == 'Debug' else 'NO')
        for category, settings, ids in [('project', values, project_configs), ('target', target, target_configs)]:
            body = ''.join(k + ' = ' + q(v) + ';' for k, v in settings.items())
            ids.append(add(category + mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{{body}}};'))
    def configs(key, ids):
        return add(key, f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    pc, tc = configs('projectconfig', project_configs), configs('targetconfig', target_configs)
    app = add('app', f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({",".join(phases)}); buildRules = (); dependencies = (); name = {name}; productName = "Cover Flow"; productReference = {product}; productType = "com.apple.product-type.application";')
    project = add('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{{app} = {{CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; }};}};}}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app});')
    project_dir.mkdir(exist_ok=True)
    (project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + ''.join(key + ' = {' + value + '};\n' for key, value in objects.items()) + '};rootObject = ' + project + ';}\n')
    scheme = project_dir / 'xcshareddata/xcschemes'
    scheme.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Cover Flow.app" BlueprintName="{name}" ReferencedContainer="container:{project_name}"/>'
    (scheme / (name + '.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
    info = dict(CFBundleDisplayName='Cover Flow', CFBundleName='Cover Flow', CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',
                CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundlePackageType='APPL', CFBundleShortVersionString='1.2.0', CFBundleVersion='3',
                LSRequiresIPhoneOS=True, UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False},
                UIBackgroundModes=['audio'], UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True,
                CFBundleDocumentTypes=[{'CFBundleTypeName': 'Audio files', 'LSHandlerRank': 'Alternate', 'LSItemContentTypes': ['public.audio', 'public.movie']}],
                ITSAppUsesNonExemptEncryption=False)
    info['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    info['UISupportedInterfaceOrientations~ipad'] = info['UISupportedInterfaceOrientations'] + ['UIInterfaceOrientationPortraitUpsideDown']
    with (folder / 'Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    print(f'Generated {device}/{project_name}: {len(sources)} source files, device family ' + ('2' if device == 'iPad' else '1'))


def main():
    assets = ROOT / 'iPad/Resources/Assets.xcassets'
    icon = assets / 'AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'Resources/AppIcon-1024.png', icon / 'AppIcon-1024.png')
    (icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2))
    (assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
    accent = assets / 'AccentColor.colorset'
    accent.mkdir(exist_ok=True)
    (accent / 'Contents.json').write_text(json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '0.79', 'green': '0.64', 'blue': '0.36', 'alpha': '1.0'}}}], 'info': {'author': 'xcode', 'version': 1}}))
    for device in ['iPad', 'iPhone']:
        generate(device)


if __name__ == '__main__':
    main()
