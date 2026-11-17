#!/bin/bash
set -euo pipefail
src="$(cd -- "$(dirname -- "$0")" && pwd)"
out="${1:-"$src/build"}"
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"
app="$out/GPT娘桌宠.app"
if [[ -e "$app" ]]; then
  printf '%s\n' '请选一个新的输出目录。'
  exit 1
fi
staging="$(mktemp -d "$out/.gptdragon-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/GPT娘桌宠.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources/Rows" "$staging/module-cache"
assets="$src"
if [[ ! -d "$assets/Actions" ]]; then
    : "${GPTDRAGON_ASSET_APP:?请指定已解压的 GPT娘桌宠.app 的完整路径，供读取公开动画资源}"
    assets="$GPTDRAGON_ASSET_APP/Contents/Resources"
fi
if [[ -f "$assets/spritesheet.webp" ]]; then
    swiftc -O -module-cache-path "$staging/module-cache" "$src/split.swift" -o "$staging/split"
    "$staging/split" "$assets/spritesheet.webp" "$bundle/Resources/Rows"
else
    cp -R "$assets/Rows/." "$bundle/Resources/Rows/"
fi
swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$staging/module-cache" \
    "$src/Activity.swift" "$src/AnimationPolicy.swift" "$src/ReviewBridge.swift" "$src/ActivityPanel.swift" "$src/Glass.swift" "$src/SpriteColor.swift" "$src/Sprites.swift" "$src/DeepSeek.swift" "$src/Quota.swift" "$src/Chat.swift" "$src/Music.swift" "$src/Placement.swift" "$src/main.swift" \
    "$src/GitHubRelease.swift" "$src/GitHubUpdater.swift" "$src/TaskCompletion.swift" \
    -o "$bundle/MacOS/GPTDragon" -lsqlite3
cp -R "$assets/Actions" "$bundle/Resources/Actions"
cp "$src/GPT娘_闲聊人设.md" "$bundle/Resources/Persona.md"
cp "$assets/AppIcon.icns" "$bundle/Resources/AppIcon.icns"
cp "$src/图集许可证.txt" "$bundle/Resources/GPTPet-LICENSE.txt"
cp "$src/Info.plist" "$bundle/Info.plist"
codesign --force --sign - "$staging/GPT娘桌宠.app"
codesign --verify --strict "$staging/GPT娘桌宠.app"
mv "$staging/GPT娘桌宠.app" "$app"
printf '%s\n' "$app"
