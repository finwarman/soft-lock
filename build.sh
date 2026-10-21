#!/bin/zsh
set -eu
project_dir="${0:A:h}"
app_path="$HOME/Applications/SoftLock.app"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$project_dir/build"
for architecture in arm64 x86_64; do
  swiftc "$project_dir/main.swift" "$project_dir/PinStore.swift" -O \
    -target "$architecture-apple-macosx13.0" -framework AppKit -framework Carbon \
    -o "$project_dir/build/SoftLock-$architecture"
done
lipo -create "$project_dir/build/SoftLock-arm64" "$project_dir/build/SoftLock-x86_64" \
  -output "$app_path/Contents/MacOS/SoftLock"
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
