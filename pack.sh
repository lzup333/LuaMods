#!/usr/bin/env bash
# ============================================================
# LuaMod 打包脚本
#
# 用法:
#   ./pack.sh                       打包全部 Mod（先清空 dist）
#   ./pack.sh all [--clean]         同上
#   ./pack.sh file <x.lua>          交互式打包单个 Lua 文件（自动生成 3 个元数据文件）
#
# 说明: 只有 file 模式是交互式。
#
# file 模式可选参数（不填则交互提示）:
#   -n, --name NAME        显示名，如 "自动钓鱼 (AutoFisher)"（交互式会提示填写）
#   -i, --id PKGID         pkgId，默认 lzup.lua.<文件名小写>
#   -a, --author AUTHOR    作者，默认 lzup333
#   -v, --version VER      版本，默认 1.0.0
#   -b, --brief TEXT       简介（brieflyDescribe）
#   -d, --desc TEXT        详细描述（description）
#   -g, --game-version V   目标游戏版本，默认 1.4.5.8
#       --multiplayer      multiplayer_safe = true（默认 false）
#       --clean            打包前清空 dist
#   -h, --help             显示帮助
#
# 包名规则: Info.json 的 name(去空格) + v + version.zip
# ============================================================
set -e

cd "$(dirname "$0")"
ROOT="$(pwd)"
DIST="$ROOT/dist"
mkdir -p "$DIST"

# ---------- 默认值 ----------
NAME=""
ID=""
AUTHOR="lzup333"
VERSION="1.0.0"
BRIEF=""
DESC=""
GAME_VERSION="1.4.5.8"
MULTIPLAYER="false"
CLEAN="false"
POSITIONALS=()

# ---------- 工具函数 ----------
die() { echo "✗ $*" >&2; exit 1; }

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# 从 Info.json 读取字段（sed，无需 jq）
info_field() {
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# 生成小写 slug（用于 pkgId）
slugify() { echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]//g'; }

# 清空 dist（优先回收站）
trash_dist() {
    [ -n "$(ls -A "$DIST" 2>/dev/null)" ] || return 0
    if command -v gio >/dev/null 2>&1; then
        find "$DIST" -mindepth 1 -maxdepth 1 -exec gio trash -f {} +
    else
        rm -rf "$DIST"/*
    fi
}

# 解析通用选项，非选项进入 POSITIONALS
parse_common() {
    POSITIONALS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--name)         NAME="$2"; shift 2 ;;
            -i|--id)           ID="$2"; shift 2 ;;
            -a|--author)       AUTHOR="$2"; shift 2 ;;
            -v|--version)      VERSION="$2"; shift 2 ;;
            -b|--brief)        BRIEF="$2"; shift 2 ;;
            -d|--desc)         DESC="$2"; shift 2 ;;
            -g|--game-version) GAME_VERSION="$2"; shift 2 ;;
            --multiplayer)     MULTIPLAYER="true"; shift ;;
            --clean)           CLEAN="true"; shift ;;
            -h|--help)         usage; exit 0 ;;
            --)                shift; POSITIONALS+=("$@"); break ;;
            -*)                die "未知选项: $1" ;;
            *)                 POSITIONALS+=("$1"); shift ;;
        esac
    done
}

# 交互式补全 file 模式信息
prompt_info() {
    local base="$1"
    [ -t 0 ] || return 0
    echo "── 填写 Mod 信息（回车用默认值）──"
    read -rp "显示名 name [${base}]: " ans; NAME="${ans:-$base}"
    ID_NOW="${ID:-lzup.lua.$(slugify "$base")}"
    read -rp "pkgId [${ID_NOW}]: " ans; ID="${ans:-$ID_NOW}"
    read -rp "作者 author [${AUTHOR}]: " ans; AUTHOR="${ans:-$AUTHOR}"
    read -rp "版本 version [${VERSION}]: " ans; VERSION="${ans:-$VERSION}"
    read -rp "简介 brieflyDescribe [${BRIEF}]: " ans; BRIEF="${ans:-$BRIEF}"
    read -rp "描述 description [${DESC}]: " ans; DESC="${ans:-$DESC}"
    read -rp "目标游戏版本 [${GAME_VERSION}]: " ans; GAME_VERSION="${ans:-$GAME_VERSION}"
}

# 写入 3 个元数据文件到 $1
write_metadata() {
    local out="$1"
    cat > "$out/Info.json" <<EOF
{
  "pkgId": "$ID",
  "name": "$NAME",
  "author": "$AUTHOR",
  "version": "$VERSION",
  "versionCode": $(date +%Y%m%d),
  "brieflyDescribe": "$BRIEF",
  "description": "$DESC",
  "features": [],
  "sizeCategory": "TINY",
  "targetGameVersion": "$GAME_VERSION",
  "minGameVersion": "$GAME_VERSION",
  "maxGameVersion": "$GAME_VERSION",
  "support": {
    "android": { "arm64": true, "arm": true, "x64": false, "x86": false },
    "windows": { "arm64": false, "arm": false, "x64": true, "x86": true },
    "linux":   { "arm64": false, "arm": false, "x64": true, "x86": false },
    "mac":     { "arm64": false, "arm": false, "x64": false, "x86": false },
    "ios":     { "arm64": false, "arm": false, "x64": false, "x86": false }
  },
  "dependence": [],
  "conflicts": [],
  "stableVerified": false,
  "experimental": true,
  "deprecated": false,
  "hasExtendedContent": false
}
EOF

    cat > "$out/luamod.json" <<EOF
{
  "main": "main.lua",
  "pkg_id": "$ID",
  "version": "$VERSION",
  "version_code": 1,
  "api_version": 1,
  "multiplayer_safe": $MULTIPLAYER
}
EOF

    cat > "$out/Manifest.json" <<EOF
{
  "type": "Mod",
  "file": "luamod.json",
  "parentLoader": "lzup333.lualoader",
  "resources": "Resources",
  "modloader": {"type": "null"},
  "plugins": {"type": "null"},
  "tefkernel": {
    "minVersion": "1.0.0"
  }
}
EOF
}

# 打包一个已含 Info.json 的目录
pack_dir() {
    local dir="$1" name ver zip
    [ -d "$dir" ] || { echo "✗ 目录不存在: $dir"; return 1; }
    [ -f "$dir/Info.json" ] || { echo "✗ 缺少 Info.json: $dir"; return 1; }
    name=$(info_field "$dir/Info.json" name)
    ver=$(info_field "$dir/Info.json" version)
    [ -n "$ver" ] || ver="0.0.0"
    zip="${name:-$(basename "$dir")}v${ver}.zip"
    zip="${zip// /}"
    rm -f "$DIST/$zip"
    ( cd "$dir" && zip -rqX "$DIST/$zip" ./* )
    echo "✓ dist/$zip"
}

# 单个 Lua 文件：交互式填写信息，生成元数据到临时目录后打包
pack_file() {
    local file="$1" base stage
    [ -f "$file" ] || die "文件不存在: $file"
    base=$(basename "$file" .lua)
    prompt_info "$base"

    stage=$(mktemp -d)
    mkdir -p "$stage/Resources/lib"
    cp "$file" "$stage/Resources/lib/main.lua"
    write_metadata "$stage"
    if pack_dir "$stage"; then
        rm -rf "$stage"
    else
        rm -rf "$stage"
        return 1
    fi
}

# 打包全部 Mod（参考原脚本）
pack_all() {
    trash_dist
    for d in */; do
        dir=${d%/}
        [ -f "$dir/Info.json" ] || continue
        pack_dir "$dir"
    done
}

# ---------- 命令分发 ----------
cmd="${1:-all}"; shift || true
case "$cmd" in
    all)
        parse_common "$@"
        [ "$CLEAN" = "true" ] && trash_dist
        pack_all
        ;;
    file)
        parse_common "$@"
        [ "$CLEAN" = "true" ] && trash_dist
        [ ${#POSITIONALS[@]} -ge 1 ] || die "用法: ./pack.sh file <x.lua> [选项]"
        for f in "${POSITIONALS[@]}"; do pack_file "$f"; done
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        die "未知命令: $cmd（用 -h 查看帮助）"
        ;;
esac
