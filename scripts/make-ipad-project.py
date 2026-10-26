#!/usr/bin/env python3
"""Regenerate the native iPad Xcode project without third-party project tools."""
from pathlib import Path
import hashlib, json, plistlib, shutil, re, os
root=Path(__file__).resolve().parents[1]; ipad=root/'iPad'
existing=(ipad/'CoverFlow-iPad.xcodeproj/project.pbxproj')
previous=existing.read_text() if existing.exists() else ''
team_match=re.search(r'DEVELOPMENT_TEAM\s*=\s*"?([A-Z0-9]{10})"?;',previous)
team=os.environ.get('COVERFLOW_APPLE_TEAM') or (team_match.group(1) if team_match else '')
bundle_match=re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([A-Za-z0-9.-]+)"?;',previous)
bundle=bundle_match.group(1) if bundle_match else 'app.coverflow.player.ipad'
shared=['Model/Models.swift','Playback/PlayerEngine.swift','Playback/GaplessAudioPlayer.swift','Playback/PCMDecoder.swift','Playback/PlaybackOrder.swift','Visualizer/VisualizerAudioBuffer.swift','Visualizer/VisualizerSignal.swift','Visualizer/NativeVisualizerSurface.swift','Downloads/MusicLookupClient.swift','Downloads/MusicDownloadViews.swift','Library/MetadataReader.swift','Lyrics/LyricsDocument.swift','Lyrics/LyricsStore.swift','Scrobbling/LastFmAPI.swift','Scrobbling/LastFmKeychain.swift','Scrobbling/LastFmScrobbler.swift','Scrobbling/ScrobbleProgress.swift','Views/ScrollingTrackTitle.swift']
sources=[str(p.relative_to(ipad)) for folder in ['Sources','Core'] for p in sorted((ipad/folder).glob('*.swift'))]+['Native/CFMDXRuntime.mm']+['../Sources/CoverFlow/'+p for p in shared]
objects={}
def uid(value):return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def add(key,value):objects[uid(key)]=value;return uid(key)
def q(value):return json.dumps(str(value))
file_ids=[];build_ids=[]
for path in sources:
    ref=add('file:'+path,'isa = PBXFileReference; lastKnownFileType = '+('sourcecode.cpp.objcpp' if path.endswith('.mm') else 'sourcecode.swift')+'; path = '+q(path)+'; sourceTree = SOURCE_ROOT;')
    file_ids.append(ref);build_ids.append(add('build:'+path,'isa = PBXBuildFile; fileRef = '+ref+';'))
resource_paths=['../Sources/CoverFlow/Visualizer/Shaders/Visualizer.metal','Resources/Assets.xcassets','Resources/ONNX-Runtime-LICENSE.txt','Resources/ONNX-Runtime-ThirdPartyNotices.txt','Resources/PrivacyInfo.xcprivacy','../Resources/Karaoke/mdx-model-data.json','../Resources/Karaoke/MDX-SOURCES.txt']
resource_ids=[]
for path in resource_paths:
    ref=add('file:'+path,'isa = PBXFileReference; lastKnownFileType = '+('folder.assetcatalog' if path.endswith('xcassets') else 'text.json' if path.endswith('json') else 'text')+'; path = '+q(path)+'; sourceTree = SOURCE_ROOT;')
    file_ids.append(ref);resource_ids.append(add('build:'+path,'isa = PBXBuildFile; fileRef = '+ref+';'))
framework='Vendor/onnxruntime.xcframework'
fref=add('file:'+framework,'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = '+q(framework)+'; sourceTree = SOURCE_ROOT;');file_ids.append(fref)
framework_ids=[add('build:'+framework,'isa = PBXBuildFile; fileRef = '+fref+';')]
for framework in ['CoreML','Accelerate','Metal','AVFoundation','MediaPlayer','Security','AudioToolbox','UIKit']:
    ref=add('system:'+framework,'isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = '+framework+'.framework; path = System/Library/Frameworks/'+framework+'.framework; sourceTree = SDKROOT;');file_ids.append(ref);framework_ids.append(add('link:'+framework,'isa = PBXBuildFile; fileRef = '+ref+';'))
product=add('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Cover Flow.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products=add('products','isa = PBXGroup; children = ('+product+'); name = Products; sourceTree = "<group>";')
main=add('main','isa = PBXGroup; children = ('+','.join(file_ids+[products])+'); sourceTree = "<group>";')
sphase=add('sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(build_ids)+'); runOnlyForDeploymentPostprocessing = 0;')
rphase=add('resources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(resource_ids)+'); runOnlyForDeploymentPostprocessing = 0;')
fphase=add('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('+','.join(framework_ids)+'); runOnlyForDeploymentPostprocessing = 0;')
project_configs=[];target_configs=[]
for mode in ['Debug','Release']:
    values={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_CXX_LANGUAGE_STANDARD':'c++17','CLANG_ENABLE_MODULES':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','SWIFT_COMPILATION_MODE':'singlefile' if mode=='Debug' else 'wholemodule','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else ''}
    target={'PRODUCT_BUNDLE_IDENTIFIER':bundle,'PRODUCT_NAME':'Cover Flow','PRODUCT_MODULE_NAME':'CoverFlowiPad','INFOPLIST_FILE':'Info.plist','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':team,'TARGETED_DEVICE_FAMILY':'2','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'AccentColor','SWIFT_OBJC_BRIDGING_HEADER':'$(SRCROOT)/CoverFlow-Bridging-Header.h','HEADER_SEARCH_PATHS':'$(SRCROOT)/Native/include','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','OTHER_LDFLAGS':'$(inherited) -ObjC','ENABLE_BITCODE':'NO','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO'}
    def config(name,values):return add(name+mode,'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+''.join(k+' = '+q(v)+';' for k,v in values.items())+'};')
    project_configs.append(config('project',values));target_configs.append(config('target',target))
pconfig=add('projectconfig','isa = XCConfigurationList; buildConfigurations = ('+','.join(project_configs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tconfig=add('targetconfig','isa = XCConfigurationList; buildConfigurations = ('+','.join(target_configs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=add('app','isa = PBXNativeTarget; buildConfigurationList = '+tconfig+'; buildPhases = ('+','.join([sphase,fphase,rphase])+'); buildRules = (); dependencies = (); name = CoverFlowiPad; productName = "Cover Flow"; productReference = '+product+'; productType = "com.apple.product-type.application";')
project=add('project','isa = PBXProject; attributes = {LastUpgradeCheck = 1600; TargetAttributes = {'+target+' = {CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; };};}; buildConfigurationList = '+pconfig+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = '+main+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = ('+target+');')
project_dir=ipad/'CoverFlow-iPad.xcodeproj';project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(key+' = {'+value+'};\n' for key,value in objects.items())+'};rootObject = '+project+';}\n')
scheme=project_dir/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
(scheme/'CoverFlowiPad.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'''+target+'''" BuildableName="Cover Flow.app" BlueprintName="CoverFlowiPad" ReferencedContainer="container:CoverFlow-iPad.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'''+target+'''" BuildableName="Cover Flow.app" BlueprintName="CoverFlowiPad" ReferencedContainer="container:CoverFlow-iPad.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
assets=ipad/'Resources/Assets.xcassets'; icon=assets/'AppIcon.appiconset';icon.mkdir(parents=True,exist_ok=True)
shutil.copyfile(root/'Resources/AppIcon-1024.png',icon/'AppIcon-1024.png')
(icon/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(assets/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
accent=assets/'AccentColor.colorset';accent.mkdir(exist_ok=True)
(accent/'Contents.json').write_text(json.dumps({'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':{'red':'0.79','green':'0.64','blue':'0.36','alpha':'1.0'}}}],'info':{'author':'xcode','version':1}}))
info={'CFBundleDisplayName':'Cover Flow','CFBundleName':'Cover Flow','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.1.0','CFBundleVersion':'2','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UIBackgroundModes':['audio'],'UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True,'CFBundleDocumentTypes':[{'CFBundleTypeName':'Audio files','LSHandlerRank':'Alternate','LSItemContentTypes':['public.audio','public.movie']}],'ITSAppUsesNonExemptEncryption':False}
with (ipad/'Info.plist').open('wb') as file:plistlib.dump(info,file)
print('Generated CoverFlow-iPad.xcodeproj with',len(sources),'source files')
