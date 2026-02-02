#!/bin/bash
set -e

echo "🔨 Building AIMonteer..."

# Build the executable
swift build -c release

# Create app bundle
APP_DIR="build/AIMonteer.app"
rm -rf build
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy files
cp .build/release/AIMonteer "$APP_DIR/Contents/MacOS/"
cp Info.plist "$APP_DIR/Contents/"

# Sign with entitlements (ad-hoc signing)
echo "🔏 Signing with entitlements..."
codesign --force --sign - --entitlements AIMonteer.entitlements "$APP_DIR/Contents/MacOS/AIMonteer"
codesign --force --sign - --entitlements AIMonteer.entitlements "$APP_DIR"

echo "✅ Built: $APP_DIR"
echo ""
echo "Run with: open build/AIMonteer.app"
echo "Or copy to Applications: cp -r build/AIMonteer.app /Applications/"
