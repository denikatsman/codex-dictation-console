#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
iconset="$project_root/.build/app-icon/AppIcon.iconset"
xcrun swift "$project_root/Resources/IconGenerator.swift" "$iconset"
iconutil -c icns "$iconset" -o "$project_root/Resources/AppIcon.icns"
cp "$iconset/icon_512x512@2x.png" "$project_root/Resources/AppIcon.png"
