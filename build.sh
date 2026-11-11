#!/bin/bash
# Builds ArnoldChopper.component, installs it for the current user, and validates it.
#   ./build.sh            build + install + auval
#   ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"

SDK=AudioUnitSDK
[ -d "$SDK" ] || git clone --depth 1 https://github.com/apple/AudioUnitSDK.git "$SDK"

OUT=build
BUNDLE="$OUT/ArnoldChopper.component"
mkdir -p "$OUT/obj" "$BUNDLE/Contents/MacOS"

FLAGS=(-arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2 -g -fvisibility=hidden -Wall -Wextra
       -Wno-unused-parameter -I"$SDK/include" -ISource)

objs=()
for src in "$SDK"/src/AudioUnitSDK/*.cpp Source/*.cpp; do
	obj="$OUT/obj/$(basename "${src%.*}").o"
	clang++ -std=c++23 "${FLAGS[@]}" -c "$src" -o "$obj"
	objs+=("$obj")
done
for src in Source/*.mm; do
	obj="$OUT/obj/$(basename "${src%.*}").o"
	clang++ -std=c++23 -fobjc-arc "${FLAGS[@]}" -c "$src" -o "$obj"
	objs+=("$obj")
done

clang++ -bundle "${FLAGS[@]}" "${objs[@]}" -o "$BUNDLE/Contents/MacOS/ArnoldChopper" \
	-framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreFoundation \
	-framework CoreMIDI -framework Accelerate -framework AppKit -framework UniformTypeIdentifiers \
	-framework SoundAnalysis -framework CoreMedia

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
echo "Built $BUNDLE"

if [ "${1:-}" != "--no-install" ]; then
	DEST="$HOME/Library/Audio/Plug-Ins/Components"
	mkdir -p "$DEST"
	rm -rf "$DEST/ChipmunkSoul.component" "$DEST/ArnoldChopper.component"  # old name too
	cp -R "$BUNDLE" "$DEST/"
	# Make the system notice the new/changed component.
	killall -9 AudioComponentRegistrar 2>/dev/null || true
	echo "Installed to $DEST"
	auval -v aumu Cmsl Antz | tail -n 25
fi
