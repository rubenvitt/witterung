#!/bin/sh
# Logiktests im Simulator ohne Instruments-Dienst: Wenn `xcodebuild test` mit
# „The test runner hung before establishing connection“ hängt (DTServiceHub),
# baut dies das Testbundle und startet es direkt per `simctl spawn xctest`.
# Aufruf: scripts/run-tests.sh <UDID eines gebooteten Simulators>
set -eu
cd "$(dirname "$0")/.."
SIM="$1"
DERIVED="$PWD/build/DerivedData"
xcodegen generate --quiet
xcodebuild -scheme Witterung -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" build-for-testing -quiet
PLAT="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PLAT/Library/Frameworks" SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PLAT/usr/lib" \
  xcrun simctl spawn "$SIM" "$PLAT/Library/Xcode/Agents/xctest" "$DERIVED/Build/Products/Debug-iphonesimulator/WitterungTests.xctest"
