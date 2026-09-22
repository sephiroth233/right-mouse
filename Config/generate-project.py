#!/usr/bin/env python3
"""Regenerate the deterministic Xcode project after adding Swift source files."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def uid(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
def obj(name, contents):
    key = uid(name)
    objects[key] = '{ ' + contents + ' };'
    return key
def ids(values): return '(' + ', '.join(values) + (',' if values else '') + ')'
def file_ref(path, kind='sourcecode.swift'):
    return obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')

base = file_ref('Config/Base.xcconfig', 'text.xcconfig')
app_files = [file_ref(str(p.relative_to(ROOT))) for p in sorted((ROOT/'Apps/RightMouse').rglob('*.swift'))]
ext_files = [file_ref(str(p.relative_to(ROOT))) for p in sorted((ROOT/'Extensions/RightMouseFinder').rglob('*.swift'))]
test_files = [file_ref(str(p.relative_to(ROOT))) for p in sorted((ROOT/'Packages/RightMouseCore/Tests/RightMouseCoreTests').rglob('*.swift'))]
app_product = obj('product:app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = RightMouse.app; sourceTree = BUILT_PRODUCTS_DIR;')
ext_product = obj('product:extension', 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = RightMouseFinder.appex; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('product:tests', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = RightMouseCoreTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = {ids([app_product, ext_product, test_product])}; name = Products; sourceTree = "<group>";')
app_group = obj('group:app', f'isa = PBXGroup; children = {ids(app_files)}; name = RightMouse; sourceTree = "<group>";')
ext_group = obj('group:extension', f'isa = PBXGroup; children = {ids(ext_files)}; name = RightMouseFinder; sourceTree = "<group>";')
test_group = obj('group:tests', f'isa = PBXGroup; children = {ids(test_files)}; name = RightMouseCoreTests; sourceTree = "<group>";')
main_group = obj('main', f'isa = PBXGroup; children = {ids([app_group, ext_group, test_group, base, products])}; sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')

def configs(name, settings):
    result=[]
    for mode in ('Debug', 'Release'):
        mode_settings = dict(settings)
        mode_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode=='Debug' else '-O'
        mode_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode=='Debug' else 'dwarf-with-dsym'
        if mode=='Debug': mode_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
        result.append(obj(f'config:{name}:{mode}', f'isa = XCBuildConfiguration; baseConfigurationReference = {base}; buildSettings = {{' + ''.join(f'{k} = {q(v)};' for k,v in mode_settings.items()) + f'}}; name = {mode};'))
    return obj('configs:'+name, f'isa = XCConfigurationList; buildConfigurations = {ids(result)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_configs=configs('project', {'SDKROOT':'macosx', 'SUPPORTED_PLATFORMS':'macosx'})
app_configs=configs('app', {'PRODUCT_NAME':'RightMouse', 'PRODUCT_BUNDLE_IDENTIFIER':'cn.rightmouse.RightMouse', 'INFOPLIST_FILE':'Config/RightMouse-Info.plist', 'CODE_SIGN_ENTITLEMENTS':'Config/RightMouse.entitlements', 'GENERATE_INFOPLIST_FILE':'NO', 'COMBINE_HIDPI_IMAGES':'YES', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
ext_configs=configs('extension', {'PRODUCT_NAME':'RightMouseFinder', 'PRODUCT_BUNDLE_IDENTIFIER':'cn.rightmouse.RightMouse.FinderExtension', 'INFOPLIST_FILE':'Config/FinderExtension-Info.plist', 'CODE_SIGN_ENTITLEMENTS':'Config/FinderExtension.entitlements', 'GENERATE_INFOPLIST_FILE':'NO', 'APPLICATION_EXTENSION_API_ONLY':'YES', 'SKIP_INSTALL':'YES', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks'})

test_configs=configs('tests', {'PRODUCT_NAME':'RightMouseCoreTests', 'PRODUCT_BUNDLE_IDENTIFIER':'cn.rightmouse.RightMouse.CoreTests', 'GENERATE_INFOPLIST_FILE':'YES', 'SKIP_INSTALL':'YES', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @loader_path/../Frameworks'})

def source_phase(name, files):
    refs=[obj(f'build:{name}:{ref}', f'isa = PBXBuildFile; fileRef = {ref};') for ref in files]
    return obj('sources:'+name, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids(refs)}; runOnlyForDeploymentPostprocessing = 0;')
def framework_phase(name):
    dep=obj('core:'+name, f'isa = XCSwiftPackageProductDependency; package = {package}; productName = RightMouseCore;')
    build=obj('link:'+name, f'isa = PBXBuildFile; productRef = {dep};')
    phase=obj('frameworks:'+name, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {ids([build])}; runOnlyForDeploymentPostprocessing = 0;')
    return dep, phase
app_core,app_frameworks=framework_phase('app')
ext_core,ext_frameworks=framework_phase('extension')
test_core,test_frameworks=framework_phase('tests')
test_sources=source_phase('tests',test_files)
test_target=obj('target:tests', f'isa = PBXNativeTarget; buildConfigurationList = {test_configs}; buildPhases = {ids([test_sources,test_frameworks])}; buildRules = (); dependencies = (); name = RightMouseCoreTests; packageProductDependencies = {ids([test_core])}; productName = RightMouseCoreTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
app_sources=source_phase('app',app_files)
ext_sources=source_phase('extension',ext_files)
embedded=obj('embed:file', f'isa = PBXBuildFile; fileRef = {ext_product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy,);}};')
embed=obj('embed:phase', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {ids([embedded])}; name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
ext_target=obj('target:extension', f'isa = PBXNativeTarget; buildConfigurationList = {ext_configs}; buildPhases = {ids([ext_sources,ext_frameworks])}; buildRules = (); dependencies = (); name = RightMouseFinder; packageProductDependencies = {ids([ext_core])}; productName = RightMouseFinder; productReference = {ext_product}; productType = "com.apple.product-type.app-extension";')
proxy=obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {ext_target}; remoteInfo = RightMouseFinder;')
dep=obj('dependency', f'isa = PBXTargetDependency; target = {ext_target}; targetProxy = {proxy};')
app_target=obj('target:app', f'isa = PBXNativeTarget; buildConfigurationList = {app_configs}; buildPhases = {ids([app_sources,app_frameworks,embed])}; buildRules = (); dependencies = {ids([dep])}; name = RightMouse; packageProductDependencies = {ids([app_core])}; productName = RightMouse; productReference = {app_product}; productType = "com.apple.product-type.application";')
project=obj('project', f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600;}}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, zh_CN, Base); mainGroup = {main_group}; packageReferences = {ids([package])}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {ids([app_target,ext_target,test_target])};')
(ROOT/'RightMouse.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n'+'\n'.join(f'{key} = {value}' for key,value in objects.items())+f'\n}};\nrootObject = {project};\n}}\n')
(ROOT/'RightMouse.xcodeproj/xcshareddata/xcschemes/RightMouse.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="RightMouse.app" BlueprintName="RightMouse" ReferencedContainer="container:RightMouse.xcodeproj"/></BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="RightMouseCoreTests.xctest" BlueprintName="RightMouseCoreTests" ReferencedContainer="container:RightMouse.xcodeproj"/></TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="RightMouse.app" BlueprintName="RightMouse" ReferencedContainer="container:RightMouse.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="RightMouse.app" BlueprintName="RightMouse" ReferencedContainer="container:RightMouse.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated Xcode project: {len(app_files)} app sources, {len(ext_files)} extension sources, {len(test_files)} test sources')
