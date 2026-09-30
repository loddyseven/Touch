#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TOUCH_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
if [[ "${TOUCH_ENABLE_MEDIA_REMOTE:-0}" == "1" ]]; then
  swift build -c release --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$SWIFTPM_MODULECACHE_OVERRIDE" -Xswiftc -DTOUCH_MEDIA_REMOTE
else
  swift build -c release --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$SWIFTPM_MODULECACHE_OVERRIDE"
fi
app="$PWD/dist/Touch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/NotchHub "$app/Contents/MacOS/NotchHub.next"
mv -f "$app/Contents/MacOS/NotchHub.next" "$app/Contents/MacOS/NotchHub"
cp Resources/Info.plist "$app/Contents/Info.plist"
for resource in Resources/*.png; do
  if [[ -f "$resource" ]]; then cp "$resource" "$app/Contents/Resources/"; fi
done
if [[ "${TOUCH_ENABLE_MEDIA_REMOTE:-0}" == "1" ]]; then
  cmake -S Vendor/mediaremote-adapter -B .build/mediaremote -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build .build/mediaremote --target MediaRemoteAdapter -j 4 >/dev/null
  mkdir -p "$app/Contents/Frameworks"
  ditto .build/mediaremote/MediaRemoteAdapter.framework "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
  cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$app/Contents/Resources/"
  cp Vendor/mediaremote-adapter/LICENSE "$app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
else
  # The normal build uses only the explicitly permitted Accessibility connection.
  rm -rf "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
  rm -f "$app/Contents/Resources/mediaremote-adapter.pl" "$app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
fi
# Finder may add metadata while the local app is being previewed.
xattr -cr "$app"
if [[ -d "$app/Contents/Frameworks/MediaRemoteAdapter.framework" ]]; then
  codesign --force --sign - "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
fi
codesign --force --sign - --identifier local.notchhub.air \
  --requirements '=designated => identifier "local.notchhub.air"' "$app"
printf 'Готово: %s\n' "$app"
