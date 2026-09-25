from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
files=sorted(root.glob('Sources/ShadeCore/*.swift'))+sorted(root.glob('CoolMap/**/*.swift'))
resources=sorted(root.glob('CoolMap/Resources/*.json'))
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
objects=[]
config=uid('app-config')
def obj(key,value): objects.append(f'{uid(key)} = {{ {value} }};'); return uid(key)
refs=[obj('app-config','isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = "Config/App.xcconfig"; sourceTree = "<group>";')]; sources=[]; bundled=[]
for f in files+resources:
    p=str(f.relative_to(root)); typ='sourcecode.swift' if f.suffix=='.swift' else 'text.json'
    r=obj('ref'+p,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = "{p}"; sourceTree = "<group>";')
    refs.append(r); b=obj('build'+p,f'isa = PBXBuildFile; fileRef = {r};')
    (sources if f in files else bundled).append(b)
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = CoolMap.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('group',f'isa = PBXGroup; children = ({",".join(refs+[product])}); sourceTree = "<group>";')
obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(sources)}); runOnlyForDeploymentPostprocessing = 0;')
obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(bundled)}); runOnlyForDeploymentPostprocessing = 0;')
obj('google-package','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/googlemaps/ios-maps-sdk"; requirement = { kind = exactVersion; version = 11.1.0; };')
obj('google-product',f'isa = XCSwiftPackageProductDependency; package = {uid("google-package")}; productName = GoogleMaps;')
obj('google-build',f'isa = PBXBuildFile; productRef = {uid("google-product")};')
obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({uid("google-build")}); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug','Release']:
    obj('project'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; }};')
    obj('target'+mode,f'''isa = XCBuildConfiguration; name = {mode}; baseConfigurationReference = {config}; buildSettings = {{ INFOPLIST_KEY_GOOGLE_MAPS_API_KEY = "$(GOOGLE_MAPS_API_KEY)"; INFOPLIST_KEY_GOOGLE_SERVICES_API_KEY = "$(GOOGLE_SERVICES_API_KEY)"; INFOPLIST_KEY_REPORTS_HOST = "$(REPORTS_HOST)"; INFOPLIST_KEY_REPORTS_PUBLIC_KEY = "$(REPORTS_PUBLIC_KEY)"; OTHER_LDFLAGS = "-ObjC"; PRODUCT_NAME = CoolMap; PRODUCT_BUNDLE_IDENTIFIER = com.hendrix.coolmap; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = "Show your position on a walking route."; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if mode=='Debug' else '-O'}"; }};''')
for scope in ['project','target']:
    obj(scope+'configs',f'isa = XCConfigurationList; buildConfigurations = ({uid(scope+"Debug")},{uid(scope+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target',f'isa = PBXNativeTarget; name = CoolMap; productName = CoolMap; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); packageProductDependencies = ({uid("google-product")});')
obj('project',f'isa = PBXProject; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {uid("group")}; packageReferences = ({uid("google-package")}); projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
p=root/'CoolMap.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
