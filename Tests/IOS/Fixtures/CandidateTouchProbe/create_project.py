import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
repo = Path(__file__).resolve().parents[4]
project = root / 'CandidateProbe.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def add(body):
    key = f'{len(objects) + 1:024X}'
    objects[key] = body
    return key

def config(settings):
    return add('isa = XCBuildConfiguration; name = Debug; buildSettings = {' + settings + '};')
def configs(settings):
    item = config(settings)
    return add(f'isa = XCConfigurationList; buildConfigurations = ({item}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')

appref = add('isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Probe.swift; sourceTree = "<group>";')
testref = add('isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProbeTests.swift; sourceTree = "<group>";')
appfile = add('isa = PBXFileReference; explicitFileType = wrapper.application; path = CandidateProbe.app; sourceTree = BUILT_PRODUCTS_DIR;')
testfile = add('isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CandidateProbeTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = add(f'isa = PBXGroup; name = Products; children = ({appfile},{testfile}); sourceTree = "<group>";')
main = add(f'isa = PBXGroup; children = ({appref},{testref},{products}); sourceTree = "<group>";')
package = add('isa = XCLocalSwiftPackageReference; relativePath = ' + json.dumps(str(repo / 'Packages/CandidateKit')) + ';')
product = add(f'isa = XCSwiftPackageProductDependency; package = {package}; productName = CandidateKit;')
link = add(f'isa = PBXBuildFile; productRef = {product};')
appbuild = add(f'isa = PBXBuildFile; fileRef = {appref};')
testbuild = add(f'isa = PBXBuildFile; fileRef = {testref};')
appsrc = add(f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({appbuild}); runOnlyForDeploymentPostprocessing = 0;')
testsrc = add(f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuild}); runOnlyForDeploymentPostprocessing = 0;')
frameworks = add(f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({link}); runOnlyForDeploymentPostprocessing = 0;')
common = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; ENABLE_TESTABILITY = YES;'
appcfg = configs(common + ' PRODUCT_BUNDLE_IDENTIFIER = app.songyan.audit.CandidateProbe; PRODUCT_NAME = "$(TARGET_NAME)"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;')
app = add(f'isa = PBXNativeTarget; buildConfigurationList = {appcfg}; buildPhases = ({appsrc},{frameworks}); buildRules = (); dependencies = (); name = CandidateProbe; packageProductDependencies = ({product}); productName = CandidateProbe; productReference = {appfile}; productType = "com.apple.product-type.application";')
dep = add(f'isa = PBXTargetDependency; target = {app};')
testcfg = configs(common + ' PRODUCT_BUNDLE_IDENTIFIER = app.songyan.audit.CandidateProbeTests; PRODUCT_NAME = "$(TARGET_NAME)"; TEST_TARGET_NAME = CandidateProbe;')
target = add(f'isa = PBXNativeTarget; buildConfigurationList = {testcfg}; buildPhases = ({testsrc}); buildRules = (); dependencies = ({dep}); name = CandidateProbeTests; productName = CandidateProbeTests; productReference = {testfile}; productType = "com.apple.product-type.bundle.ui-testing";')
projcfg = configs(common)
proj = add(f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700;}}; buildConfigurationList = {projcfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; packageReferences = ({package}); productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app},{target});')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{k} = {{ {v} }};' for k,v in objects.items()) + f'\n}}; rootObject = {proj}; }}\n')
scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
def ref(ident, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:CandidateProbe.xcodeproj"/>'
(scheme / 'CandidateProbe.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(app,'CandidateProbe.app')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(target,'CandidateProbeTests.xctest')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'CandidateProbe.app')}</BuildableProductRunnable></LaunchAction></Scheme>''')
