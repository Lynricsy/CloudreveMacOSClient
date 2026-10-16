#!/usr/bin/env bash
# Linux 一键检查：包构建与测试、SwiftLint、macOS 专属源码语法检查、XcodeGen 规范校验。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFTC="${SWIFTC:-/root/.local/share/swift/usr/bin/swiftc}"

# 过滤 Linux 上 libxml2 版本告警噪音；pipefail 保证返回原命令退出码
quiet_libxml() {
    "$@" 2>&1 | { grep -v 'libxml2' || true; }
}

echo "==> [1/4] swift build / swift test（Packages/CloudreveKit）"
(
    cd Packages/CloudreveKit
    quiet_libxml swift build
    quiet_libxml swift test
)

echo "==> [2/4] swiftlint --strict"
quiet_libxml swiftlint lint --strict --quiet

echo "==> [3/4] swiftc -parse macOS 专属源码"
dirs=()
for dir in App FileProviderExtension Shared; do
    [[ -d "$dir" ]] && dirs+=("$dir")
done
if ((${#dirs[@]} > 0)); then
    while IFS= read -r -d '' file; do
        "$SWIFTC" -parse "$file"
    done < <(find "${dirs[@]}" -name '*.swift' -print0)
fi

echo "==> [4/4] XcodeGen 规范校验"
if [[ -f project.yml ]]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "未找到 xcodegen，请先执行 Scripts/install-xcodegen-linux.sh" >&2
        exit 1
    fi
    out="$(mktemp -d /tmp/cloudreve-xcodegen.XXXXXX)"
    trap 'rm -rf "$out"' EXIT
    quiet_libxml xcodegen generate --spec project.yml --project "$out" --quiet
    [[ -d "$out/Cloudreve.xcodeproj" ]] || { echo "XcodeGen 未生成 Cloudreve.xcodeproj" >&2; exit 1; }
fi

echo "==> 全部通过"
