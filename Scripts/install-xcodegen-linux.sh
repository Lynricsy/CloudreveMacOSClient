#!/usr/bin/env bash
# 在 Linux 上从源码构建 XcodeGen 并安装到 ~/.local/bin（用于校验 project.yml）。
set -euo pipefail

rm -rf /tmp/XcodeGen
git clone --depth 1 https://github.com/yonaskolb/XcodeGen /tmp/XcodeGen
cd /tmp/XcodeGen
swift build -c release --product xcodegen
mkdir -p "$HOME/.local/bin"
install .build/release/xcodegen "$HOME/.local/bin/"
echo "已安装：$HOME/.local/bin/xcodegen"
