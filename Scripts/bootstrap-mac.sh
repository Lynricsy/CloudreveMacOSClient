#!/usr/bin/env bash
# Mac 上一键生成 Xcode 工程并构建 Debug。需要 Xcode 27 与 `brew install xcodegen`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f Config/Local.xcconfig ]]; then
    cp Config/Local.xcconfig.example Config/Local.xcconfig
    echo "已创建 Config/Local.xcconfig，请填入你的 DEVELOPMENT_TEAM 后重新运行。" >&2
    exit 1
fi

xcodegen generate
xcodebuild -project Cloudreve.xcodeproj -scheme Cloudreve -configuration Debug build
