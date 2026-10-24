#!/bin/bash
# Runs the bench suite in a throwaway UniveEngine home and prints a median table.
#
#   bench/run.sh --work <dir> [--engine <engine dir>] [--runs 3] [--seconds 8] [--tests cpu,files,d3d11,d3d9]
#                [--backends dxvk,wined3d] [--keep] [--no-build]
#
# <dir> gets a private UNIVE_HOME (Engines/<version> is a symlink to the engine, read-only use) with a fresh
# "steam" bottle. Windows programs are started with `unive run`, i.e. the app's own WineRunner: same environment,
# same WINEDLLOVERRIDES, same NativeBackendDLLs.prepare. Nothing outside <dir> is written.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

work=""; engine_dir="$HOME/Library/Application Support/UniveGame/Engines/1.1.0"
runs=3; seconds=8; tests="cpu,files,d3d11,d3d9"; backends="dxvk,wined3d"; keep=0; build=1
while [ $# -gt 0 ]; do
    case "$1" in
        --work) work="$2"; shift 2 ;;
        --engine) engine_dir="$2"; shift 2 ;;
        --runs) runs="$2"; shift 2 ;;
        --seconds) seconds="$2"; shift 2 ;;
        --tests) tests="$2"; shift 2 ;;
        --backends) backends="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        --no-build) build=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
[ -n "$work" ] || { echo "usage: $0 --work <throwaway dir> [options]" >&2; exit 64; }
mkdir -p "$work"; work="$(cd "$work" && pwd -P)"
case "$work" in
    "$HOME/Library/"*|"$HOME"|"/") echo "refusing to use $work as the work folder" >&2; exit 64 ;;
esac
if [ -n "$(ls -A "$work")" ] && [ ! -f "$work/.unive-bench" ]; then
    echo "$work is not empty and wasn't made by this script; pick another folder" >&2; exit 64
fi
touch "$work/.unive-bench"
[ -f "$engine_dir/ENGINE.json" ] || { echo "no ENGINE.json in $engine_dir" >&2; exit 1; }
version="$(plutil -extract version raw "$engine_dir/ENGINE.json")"

if [ $build = 1 ]; then
    "$here/build.sh" >/dev/null
    (cd "$repo" && DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        swift build --product unive 2>&1 | tail -1)
fi
unive="$repo/.build/debug/unive"
out="$here/out"

export UNIVE_HOME="$work/home"
mkdir -p "$UNIVE_HOME/Engines" "$work/logs"
# A real folder of symlinks (EngineLocator doesn't list a symlinked engine folder); the engine is only read.
rm -rf "$UNIVE_HOME/Engines/$version"; mkdir -p "$UNIVE_HOME/Engines/$version"
for item in "$engine_dir"/*; do ln -s "$item" "$UNIVE_HOME/Engines/$version/"; done
bottle="$UNIVE_HOME/Bottles/steam"
wineroot="$engine_dir/wine"   # same lookup as Engine.findWineRoot
for app in "$engine_dir"/*.app; do [ -x "$app/Contents/Resources/wine/bin/wine" ] && wineroot="$app/Contents/Resources/wine"; done
[ -x "$wineroot/bin/wine" ] || { echo "no wine binary in $engine_dir" >&2; exit 1; }

# The environment the app gives Wine for this bottle (backend: the app's default).
app_env() { "$unive" env --bottle steam --engine "$version" "$@" | grep -v '^#'; }
kill_bottle() {
    [ -d "$bottle" ] || return 0
    local e=(); while IFS= read -r l; do e+=("$l"); done < <(app_env)
    env -i "${e[@]}" "$wineroot/bin/wineserver" -k 2>/dev/null || true
}
trap kill_bottle EXIT

if [ $keep = 0 ] && [ -d "$bottle" ]; then kill_bottle; rm -rf "$bottle"; fi
if [ ! -d "$bottle/drive_c/windows" ]; then
    echo "== creating bottle $bottle (engine $version)"
    mkdir -p "$bottle"
    e=(); while IFS= read -r l; do e+=("$l"); done < <(app_env)
    t=$(date +%s)
    env -i "${e[@]}" "$wineroot/bin/wine" wineboot --init >"$work/logs/wineboot.log" 2>&1
    env -i "${e[@]}" "$wineroot/bin/wineserver" -w
    echo "   wineboot took $(( $(date +%s) - t )) s"
fi
mkdir -p "$bottle/drive_c/bench"
cp "$out"/win/*.exe "$bottle/drive_c/bench/"

# unive runs from here: DXVK writes its state cache (<exe>.dxvk-cache) into the working directory.
mkdir -p "$work/cwd"; cd "$work/cwd"

results="$work/results.tsv"
[ -f "$results" ] && mv "$results" "$results.$(date +%s).old"
printf 'test\tbackend\trun\tmetric\tvalue\tunit\n' > "$results"

# timeout <seconds> cmd...  (kills the command, the bottle is cleaned up afterwards)
timeout_run() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }

run_wine() {   # test backend run program args...
    local test="$1" backend="$2" run="$3"; shift 3
    local tag="$test-$backend-$run" status=0 flag="$backend"
    [ "$backend" = wine ] && flag=auto   # cpu/files: whatever the app picks by default
    timeout_run $(( ${seconds%.*} + 120 )) "$unive" run --bottle steam --engine "$version" --backend "$flag" \
        "$@" >"$work/logs/$tag.unive.txt" 2>&1 || status=$?
    local log; log="$(sed -n 's/^log: //p' "$work/logs/$tag.unive.txt" | head -1)"
    if [ -n "$log" ] && [ -f "$log" ]; then cp "$log" "$work/logs/$tag.log"; else : > "$work/logs/$tag.log"; fi
    awk -v t="$test" -v b="$backend" -v r="$run" '$1=="RESULT"{printf "%s\t%s\t%s\t%s\t%s\t%s\n",t,b,r,$2,$3,$4}' \
        "$work/logs/$tag.log" >> "$results"
    local dxvk; dxvk=$(grep -c 'info:  DXVK: v' "$work/logs/$tag.log" || true)
    printf '%s\t%s\t%s\tdxvk_banner\t%s\tlines\n' "$test" "$backend" "$run" "$dxvk" >> "$results"
    printf '%s\t%s\t%s\texit\t%s\tstatus\n' "$test" "$backend" "$run" "$status" >> "$results"
    local info; info="$(grep -m1 '^INFO' "$work/logs/$tag.log" || true)"
    echo "   $tag: exit $status, dxvk banner $dxvk${info:+, $info}"
    grep '^ERROR' "$work/logs/$tag.log" | sed 's/^/      /' || true
    if [ $status -ne 0 ] && [ $status -ne 142 ]; then kill_bottle; fi
    [ $status -eq 142 ] && { echo "      timed out"; kill_bottle; }
    return 0
}

run_native() {   # test variant run program args...
    local test="$1" variant="$2" run="$3"; shift 3
    "$@" > "$work/logs/$test-$variant-$run.log" 2>&1 || echo "   $test-$variant-$run failed"
    awk -v t="$test" -v b="$variant" -v r="$run" '$1=="RESULT"{printf "%s\t%s\t%s\t%s\t%s\t%s\n",t,b,r,$2,$3,$4}' \
        "$work/logs/$test-$variant-$run.log" >> "$results"
}

has() { [[ ",$tests," == *",$1,"* ]]; }
IFS=',' read -r -a bks <<< "$backends"
for run in $(seq 1 "$runs"); do
    echo "== run $run/$runs"
    if has cpu; then
        run_wine cpu wine "$run" 'C:\bench\cpu.exe'
        run_native cpu native-arm64 "$run" "$out/mac/cpu-arm64"
        run_native cpu native-x86_64 "$run" arch -x86_64 "$out/mac/cpu-x86_64"
    fi
    if has files; then
        run_wine files wine "$run" 'C:\bench\files.exe' 'C:\bench\io'
        run_native files native-arm64 "$run" "$out/mac/files-arm64" "$work/native-io"
    fi
    for b in "${bks[@]}"; do
        has d3d11 && run_wine d3d11 "$b" "$run" 'C:\bench\d3d11.exe' "$seconds"
        has d3d9 && run_wine d3d9 "$b" "$run" 'C:\bench\d3d9.exe' "$seconds"
    done
done
kill_bottle
trap - EXIT
echo
/usr/bin/python3 -I "$here/summarize.py" "$results"
echo
echo "raw results: $results"
echo "logs:        $work/logs"
