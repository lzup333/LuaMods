#!/usr/bin/env bash
# 打包全部 LuaMod: ./pack.sh
# 打包前把 dist 下已有内容移到回收站
# 包名 = Info.json 的 name(去空格) + v + version
set -e
cd "$(dirname "$0")"
mkdir -p dist
if [ -n "$(ls -A dist)" ]; then
    find dist -mindepth 1 -maxdepth 1 -exec gio trash -f {} +
fi
for d in */; do
    dir=${d%/}
    [ -f "$dir/Info.json" ] || continue
    name=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/Info.json" | head -1)
    ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/Info.json" | head -1)
    zip="${name:-$dir}v${ver}.zip"; zip=${zip// /}
    ( cd "$dir" && zip -rqX "../dist/$zip" ./* )
    echo "✓ dist/$zip"
done
