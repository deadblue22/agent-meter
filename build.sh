#!/bin/bash
# Builds "Agent Meter.app". Pass `install` to also copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Agent Meter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AgentMeter "$APP/Contents/MacOS/AgentMeter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon: compile the Icon Composer document into Assets.car (macOS 26 Liquid Glass icon)
# and AppIcon.icns (older macOS versions)
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist build/icon-partial.plist >/dev/null
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Agent Meter.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Agent Meter.app"
fi
