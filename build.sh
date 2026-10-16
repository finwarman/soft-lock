#!/bin/zsh
set -eu
app_path="$HOME/Applications/SoftLock.app"
mkdir -p "$app_path/Contents/MacOS"
swiftc "${0:A:h}/main.swift" -O -framework AppKit -framework Carbon -o "$app_path/Contents/MacOS/SoftLock"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SoftLock</string>
<key>CFBundleIdentifier</key><string>local.fin.softlock</string>
<key>CFBundleName</key><string>SoftLock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"
