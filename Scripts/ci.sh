#!/bin/zsh

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly package_path="$repository_root/Packages/VibeManagerKit"
readonly derived_data_path="${DERIVED_DATA_PATH:-$repository_root/DerivedData/CI}"
readonly module_cache_path="$repository_root/.build/ModuleCache"
readonly source_packages_path="$derived_data_path/SourcePackages"
# Xcode's compilation cache, keyed by what is compiled rather than by dates: a fresh checkout finds
# what an earlier run compiled when CI restores this folder. SwiftPM has no such cache.
readonly compilation_cache_path="${COMPILATION_CACHE_PATH:-$repository_root/DerivedData/CompilationCache}"

# What to run: `package` (checks and the package's tests), `macos` (the application, Debug and
# Release), `companion` (the iOS companion), or everything, in that order, by default. CI runs the
# three at once, on three runners.
readonly stage="${1:-all}"
case "$stage" in
  all|package|macos|companion) ;;
  *) echo "usage: $0 [all|package|macos|companion]" >&2; exit 64;;
esac
runs() { [[ "$stage" == all || "$stage" == "$1" ]]; }

xcodebuild_cached() {
  xcodebuild "$@" \
    -derivedDataPath "$derived_data_path" \
    -clonedSourcePackagesDirPath "$source_packages_path" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    COMPILATION_CACHE_CAS_PATH="$compilation_cache_path"
}

# Run from an agent's terminal, the suites would find its session's activity log and report into
# it: a mock agent's `SessionEnd` takes the real agent's pending question away (#271).
unset VIBE_AGENT_ACTIVITY_LOG

export CLANG_MODULE_CACHE_PATH="$module_cache_path"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache_path"

cd "$repository_root"

if runs package; then
echo "Checking Swift formatting"
xcrun swift-format lint --recursive \
  App \
  UITests \
  Packages/VibeManagerKit/Sources \
  Packages/VibeManagerKit/Tests \
  Packages/VibeManagerKit/Tools \
  Packages/VibeManagerKit/Package.swift \
  Packages/ReleaseTools/Sources \
  Packages/ReleaseTools/Tests \
  Packages/ReleaseTools/Package.swift \
  Packages/CompanionKit/Sources \
  Packages/CompanionKit/Tests \
  Packages/CompanionKit/Package.swift

echo "Checking the translations"
Scripts/test-check-localizations.sh
Scripts/check-localizations.sh

echo "Checking what is handed to macOS to open"
Scripts/test-check-external-opens.sh
Scripts/check-external-opens.sh

echo "Testing the appcast generator"
swift test --package-path "$repository_root/Packages/ReleaseTools"

echo "Testing the mobile companion's package"
# Offline: the records, the rules read from them and the link's wire. CloudKit itself needs an
# iCloud account, which CI does not have.
swift build --package-path "$repository_root/Packages/CompanionKit" --build-tests \
  -Xswiftc -warnings-as-errors
swift test --package-path "$repository_root/Packages/CompanionKit" --skip-build

echo "Running package tests"
# Validate package sources with warnings promoted to errors here. Do not pass the equivalent
# build setting globally to xcodebuild: Xcode 16.4 suppresses warnings for package dependencies,
# and combining that inherited flag with warnings-as-errors makes the compiler reject both.
swift build \
  --package-path "$package_path" \
  --build-tests \
  -Xswiftc -warnings-as-errors
# The SwiftPM of Xcode 16.4 does not compile string catalogs: see the script.
"$repository_root/Scripts/compile-package-catalogs.sh"
swift test \
  --package-path "$package_path" \
  --skip-build
fi

if runs macos; then
echo "Building the macOS application, and its interface smoke test"
# The smoke test is compiled here so that a pull request cannot break it; it is run by the
# `ui-smoke` job, which needs a graphical session (`Scripts/ui-smoke.sh`).
xcodebuild_cached \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Debug \
  -destination 'platform=macOS' \
  build-for-testing

echo "Building the macOS application in Release"
# Whole-module optimization, -O and dead stripping are otherwise first compiled on the day of a
# release. Unsigned here: signing and notarization are `Scripts/release.sh`'s, on the maintainer's
# Mac.
xcodebuild_cached \
  -project VibeManager.xcodeproj \
  -scheme VibeManager \
  -configuration Release \
  -destination 'platform=macOS' \
  build
fi

if runs companion; then
echo "Building the mobile companion for the iOS simulator"
# Unsigned: its App ID, iCloud container and push entitlement are the maintainer's (#347).
xcodebuild_cached \
  -project VibeManager.xcodeproj \
  -scheme VibeCompanion \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build

echo "Building the mobile companion in Release for the iPhone"
# What Scripts/testflight.sh archives at a release, first compiled on a pull request. Unsigned.
xcodebuild_cached \
  -project VibeManager.xcodeproj \
  -scheme VibeCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  build
fi
