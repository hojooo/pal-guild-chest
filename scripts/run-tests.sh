#!/usr/bin/env sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_runtime="$repository_root/third_party/lua-5.4.8/src/lua"

if [ ! -x "$lua_runtime" ]; then
    printf '%s\n' "Lua 5.4.8 test runtime is missing; run: make -C third_party/lua-5.4.8 all" >&2
    exit 1
fi

cd "$repository_root"

if [ "$#" -eq 0 ]; then
    set -- tests/unit/*.lua tests/integration/*.lua
fi

exec "$lua_runtime" tests/run.lua "$@"
