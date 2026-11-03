#!/usr/bin/env python3
"""Generates ClaudeUsageWidget.xcodeproj reproducibly (no xcodegen needed).

Usage:  python3 tools/generate_project.py
        BUNDLE_PREFIX=com.yourname.ClaudeUsageWidget python3 tools/generate_project.py

BUNDLE_PREFIX is the bundle identifier of the app (default com.example.ClaudeUsageWidget); the widget
extension gets "<prefix>.Widget" and the unit tests "<prefix>Tests". Pick your own prefix to avoid
clashing with other builds on the same Mac. IDs are derived from a hash of the name, so running the
script twice produces the same file.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "ClaudeUsageWidget"
BUNDLE_APP = os.environ.get("BUNDLE_PREFIX", "com.example.ClaudeUsageWidget")
DEPLOY = "14.0"  # minimum macOS: 14 (Sonoma)

SHARED = ["Shared/StatsModel.swift", "Shared/StatsFormat.swift", "Shared/StatsLoader.swift", "Shared/ModelNaming.swift",
          "Shared/UsageReport.swift", "Shared/PanelLink.swift", "Shared/ModelColor.swift"]
APP = ["App/ClaudeUsageApp.swift", "App/Updater.swift", "App/PanelStore.swift", "App/PanelView.swift"]
STRINGS = "Resources/Localizable.xcstrings"
APP_RESOURCES = ["App/Assets.xcassets", STRINGS]  # AppIcon: the widget gallery uses the app icon
WIDGET_RESOURCES = [STRINGS]
WIDGET = ["Widget/UsageWidget.swift", "Widget/WidgetViews.swift", "Widget/ModelIntent.swift"]
TESTS = ["Tests/StatsParserTests.swift", "Tests/StatsLoaderTests.swift", "Tests/AppBundleTests.swift", "Tests/UsageReportTests.swift",
         "Tests/LocalizationTests.swift"]
OTHER = ["App/Info.plist", "App/App.entitlements", "Widget/Info.plist", "Widget/Widget.entitlements"]


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def q(value):
    """Quotes a value for Xcode's ASCII plist format."""
    if isinstance(value, list):
        return "(\n" + "".join(f"\t\t\t\t\t{q(v)},\n" for v in value) + "\t\t\t\t)"
    s = str(value)
    if s and all(c.isalnum() or c in "._/" for c in s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def as_dict(d, indent="\t\t\t\t"):
    return "{\n" + "".join(f"{indent}{k} = {q(v)};\n" for k, v in d.items()) + indent[:-1] + "}"


objects = {}


def add_object(id_, body):
    objects[id_] = body


def file_type(path):
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    if path.endswith(".xcstrings"):
        return "text.json.xcstrings"
    if path.endswith(".plist"):
        return "text.plist.xml"
    return "text.plist.entitlements"


# --- File references and groups ---
groups = {}
for path in dict.fromkeys(SHARED + APP + WIDGET + TESTS + OTHER + APP_RESOURCES + WIDGET_RESOURCES):
    folder, name = path.split("/")
    add_object(oid("ref:" + path),
               f"{{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; path = {q(name)}; sourceTree = \"<group>\"; }}")
    groups.setdefault(folder, []).append(oid("ref:" + path))

products = {
    "app": ("ClaudeUsageWidget.app", "wrapper.application"),
    "widget": ("ClaudeUsageWidgetExtension.appex", "wrapper.app-extension"),
    "tests": ("ClaudeUsageWidgetTests.xctest", "wrapper.cfbundle"),
}
for key, (name, kind) in products.items():
    add_object(oid("prod:" + key),
               f"{{isa = PBXFileReference; explicitFileType = {q(kind)}; includeInIndex = 0; path = {q(name)}; sourceTree = BUILT_PRODUCTS_DIR; }}")

for folder, children in groups.items():
    add_object(oid("group:" + folder),
               "{isa = PBXGroup; children = (" + ", ".join(children) + f"); path = {folder}; sourceTree = \"<group>\"; }}")
add_object(oid("group:Products"),
           "{isa = PBXGroup; children = (" + ", ".join(oid("prod:" + k) for k in products) + "); name = Products; sourceTree = \"<group>\"; }")
add_object(oid("group:main"),
           "{isa = PBXGroup; children = (" + ", ".join(oid("group:" + c) for c in groups) + ", " + oid("group:Products") + "); sourceTree = \"<group>\"; }")


# --- Targets ---
def build_phases(target, files, resources=()):
    ids = []
    for path in files:
        bid = oid(f"build:{target}:{path}")
        add_object(bid, f"{{isa = PBXBuildFile; fileRef = {oid('ref:' + path)}; }}")
        ids.append(bid)
    add_object(oid(f"phase:{target}:sources"),
               "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ", ".join(ids) + "); runOnlyForDeploymentPostprocessing = 0; }")
    add_object(oid(f"phase:{target}:frameworks"),
               "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }")
    resource_ids = []
    for path in resources:
        bid = oid(f"build:{target}:{path}")
        add_object(bid, f"{{isa = PBXBuildFile; fileRef = {oid('ref:' + path)}; }}")
        resource_ids.append(bid)
    add_object(oid(f"phase:{target}:resources"),
               "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (" + ", ".join(resource_ids) + "); runOnlyForDeploymentPostprocessing = 0; }")
    return [oid(f"phase:{target}:{f}") for f in ("sources", "frameworks", "resources")]


def configs(target, settings):
    ids = []
    for name in ("Debug", "Release"):
        cid = oid(f"config:{target}:{name}")
        add_object(cid, "{isa = XCBuildConfiguration; buildSettings = " + as_dict(settings) + f"; name = {name}; }}")
        ids.append(cid)
    lid = oid(f"list:{target}")
    add_object(lid, "{isa = XCConfigurationList; buildConfigurations = (" + ", ".join(ids) +
               "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }")
    return lid


common = {
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual",
    "DEVELOPMENT_TEAM": "",
    "PROVISIONING_PROFILE_SPECIFIER": "",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "SWIFT_VERSION": "5.0",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOY,
}
localized = {
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

# Widget extension
phases_w = build_phases("widget", SHARED + WIDGET, WIDGET_RESOURCES)
configs_w = configs("widget", {**common, **localized,
    "PRODUCT_NAME": "ClaudeUsageWidgetExtension",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_APP + ".Widget",
    "INFOPLIST_FILE": "Widget/Info.plist",
    "CODE_SIGN_ENTITLEMENTS": "Widget/Widget.entitlements",
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "SKIP_INSTALL": "YES",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
})
add_object(oid("target:widget"),
           "{isa = PBXNativeTarget; buildConfigurationList = " + configs_w + "; buildPhases = (" + ", ".join(phases_w) +
           "); buildRules = (); dependencies = (); name = ClaudeUsageWidgetExtension; productName = ClaudeUsageWidgetExtension; productReference = "
           + oid("prod:widget") + "; productType = \"com.apple.product-type.app-extension\"; }")

# Host app (embeds the extension in Contents/PlugIns)
embed = oid("build:app:embed-widget")
add_object(embed, "{isa = PBXBuildFile; fileRef = " + oid("prod:widget") + "; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; }")
add_object(oid("phase:app:embed"),
           "{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = (" + embed +
           "); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; }")
add_object(oid("proxy:widget"),
           "{isa = PBXContainerItemProxy; containerPortal = " + oid("project") + "; proxyType = 1; remoteGlobalIDString = "
           + oid("target:widget") + "; remoteInfo = ClaudeUsageWidgetExtension; }")
add_object(oid("dep:widget"),
           "{isa = PBXTargetDependency; target = " + oid("target:widget") + "; targetProxy = " + oid("proxy:widget") + "; }")
phases_a = build_phases("app", SHARED + APP, APP_RESOURCES) + [oid("phase:app:embed")]
configs_a = configs("app", {**common, **localized,
    "PRODUCT_NAME": "ClaudeUsageWidget",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_APP,
    "INFOPLIST_FILE": "App/Info.plist",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_ENTITLEMENTS": "App/App.entitlements",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
})
add_object(oid("target:app"),
           "{isa = PBXNativeTarget; buildConfigurationList = " + configs_a + "; buildPhases = (" + ", ".join(phases_a) +
           "); buildRules = (); dependencies = (" + oid("dep:widget") + "); name = ClaudeUsageWidget; productName = ClaudeUsageWidget; productReference = "
           + oid("prod:app") + "; productType = \"com.apple.product-type.application\"; }")

# Unit tests (no host app: they compile Shared directly)
phases_t = build_phases("tests", SHARED + TESTS + ["App/Updater.swift"])
configs_t = configs("tests", {**common,
    "PRODUCT_NAME": "ClaudeUsageWidgetTests",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_APP + "Tests",
    "GENERATE_INFOPLIST_FILE": "YES",
})
add_object(oid("target:tests"),
           "{isa = PBXNativeTarget; buildConfigurationList = " + configs_t + "; buildPhases = (" + ", ".join(phases_t) +
           "); buildRules = (); dependencies = (); name = ClaudeUsageWidgetTests; productName = ClaudeUsageWidgetTests; productReference = "
           + oid("prod:tests") + "; productType = \"com.apple.product-type.bundle.unit-test\"; }")

# Project
project_debug = {"SDKROOT": "macosx", "ALWAYS_SEARCH_USER_PATHS": "NO", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "DEBUG_INFORMATION_FORMAT": "dwarf",
                 "ENABLE_TESTABILITY": "YES", "MACOSX_DEPLOYMENT_TARGET": DEPLOY}
project_release = {"SDKROOT": "macosx", "ALWAYS_SEARCH_USER_PATHS": "NO", "SWIFT_COMPILATION_MODE": "wholemodule",
                   "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "MACOSX_DEPLOYMENT_TARGET": DEPLOY}
for name, project_settings in (("Debug", project_debug), ("Release", project_release)):
    add_object(oid("config:project:" + name), "{isa = XCBuildConfiguration; buildSettings = " + as_dict(project_settings) + f"; name = {name}; }}")
add_object(oid("list:project"),
           "{isa = XCConfigurationList; buildConfigurations = (" + oid("config:project:Debug") + ", " + oid("config:project:Release")
           + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }")
add_object(oid("project"),
           "{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2700; }; buildConfigurationList = "
           + oid("list:project") + "; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, es, ); mainGroup = "
           + oid("group:main") + "; productRefGroup = " + oid("group:Products") + "; projectDirPath = \"\"; projectRoot = \"\"; targets = ("
           + ", ".join(oid("target:" + t) for t in ("app", "widget", "tests")) + "); }")

pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"
for id_ in sorted(objects):
    pbx += f"\t\t{id_} = {objects[id_]};\n"
pbx += f"\t}};\n\trootObject = {oid('project')};\n}}\n"

dest = os.path.join(ROOT, PROJECT + ".xcodeproj")
os.makedirs(os.path.join(dest, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(dest, "project.pbxproj"), "w") as f:
    f.write(pbx)


def ref_xml(target, name, product):
    return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{oid("target:" + target)}" '
            f'BuildableName = "{product}" BlueprintName = "{name}" ReferencedContainer = "container:{PROJECT}.xcodeproj"></BuildableReference>')


scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref_xml("app", "ClaudeUsageWidget", "ClaudeUsageWidget.app")}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {ref_xml("tests", "ClaudeUsageWidgetTests", "ClaudeUsageWidgetTests.xctest")}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref_xml("app", "ClaudeUsageWidget", "ClaudeUsageWidget.app")}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
with open(os.path.join(dest, "xcshareddata", "xcschemes", PROJECT + ".xcscheme"), "w") as f:
    f.write(scheme)
print("Generated", dest)
