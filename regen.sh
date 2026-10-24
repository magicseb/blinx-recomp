#!/usr/bin/env bash
# Regenerate the recompiled C from default.xbe with the xboxrecomp toolkit
# (../xboxrecomp), in the order Takedawn's regen.sh uses:
#
#   xbe_parser    section layout -> build/xr/analysis.json
#   disasm        ALL code sections, never --text-only: Fable keeps 118
#                 demand-loaded sections (S_Q* quests and the rest) beside the
#                 XDK ones, and without them there are no function boundaries.
#   func_id       library-function identification (CRT, XDK).
#   abi_analysis  calling convention / params / return type.
#   recomp        emits the C into src/recomp/gen (gitignored).
#
# Nothing here is committed output: build/ and gen/ are regenerable from the
# user's own default.xbe.
#
# Usage: ./regen.sh [--disasm]

set -uo pipefail

FABLE="$(cd "$(dirname "$0")" && pwd)"
RECOMP="${XBOXRECOMP_DIR:-$FABLE/../xboxrecomp}"
XBE="${FABLE_XBE:-$FABLE/../game_files/default.xbe}"
OUT="$FABLE/build/xr"

# The Python that has capstone. Not the py launcher: on this machine it points
# at a stale install. PYTHON=... overrides.
PY="${PYTHON:-python}"
"$PY" -c "import capstone" 2>/dev/null || { echo "$PY has no capstone: $PY -m pip install capstone"; exit 1; }

if [[ ! -f "$XBE" ]]; then
    echo "missing $XBE -- extract it from your own disc image:"
    echo "  (cd $RECOMP && $PY -m tools.xiso unpack <jeu.iso> -o ../game_files/)"
    exit 1
fi
mkdir -p "$OUT"

SEEDS=()
[[ -f "$FABLE/config/seed_functions.json" ]] && \
    SEEDS=(--seed-functions "$FABLE/config/seed_functions.json")
SPIN=()
[[ -f "$FABLE/config/spin_waits.json" ]] && \
    SPIN=(--spin-waits "$FABLE/config/spin_waits.json")

if [[ "${1:-}" == "--disasm" || ! -f "$OUT/disasm/functions.json" ]]; then
    echo "==> xbe_parser"
    (cd "$RECOMP" && "$PY" -m tools.xbe_parser "$XBE" \
        --json "$OUT/analysis.json" --quiet) || exit 1

    echo "==> disasm"
    (cd "$RECOMP" && "$PY" -m tools.disasm "$XBE" \
        --analysis-json "$OUT/analysis.json" ${SEEDS[@]+"${SEEDS[@]}"} \
        -o "$OUT/disasm" -v) > "$OUT/disasm.log" 2>&1 || { tail -20 "$OUT/disasm.log"; exit 1; }
    tr '\r' '\n' < "$OUT/disasm.log" | grep -E "Total functions|Reachable|Seeded" || true
fi

echo "==> func_id"
(cd "$RECOMP" && "$PY" -m tools.func_id "$XBE" \
    --functions "$OUT/disasm/functions.json" \
    --strings   "$OUT/disasm/strings.json" \
    --xrefs     "$OUT/disasm/xrefs.json" \
    -o "$OUT/func_id" | tail -1) || exit 1

echo "==> abi_analysis"
(cd "$RECOMP" && "$PY" -m tools.abi_analysis "$XBE" \
    --functions  "$OUT/disasm/functions.json" \
    --identified "$OUT/func_id/identified_functions.json" \
    --output-dir "$OUT/abi" | tail -1) || exit 1

# --split 250, not 1000: Fable has twice Burnout 3's code, and a 1000-function
# chunk is a single translation unit of hundreds of MB.
echo "==> recomp"
(cd "$RECOMP" && "$PY" -m tools.recomp "$XBE" --all --split 250 \
    --disasm-dir  "$OUT/disasm" \
    --func-id-dir "$OUT/func_id" \
    --abi-dir     "$OUT/abi" \
    --exclude-manual "$FABLE/src/recomp_manual.c" \
    ${SPIN[@]+"${SPIN[@]}"} \
    --gen-dir     "$FABLE/src/recomp/gen" \
    -o "$OUT/recomp"
) > "$OUT/recomp.log" 2>&1
st=$?
grep -aE "unresolved|functions \(|Complete" "$OUT/recomp.log" || true
if [ $st -ne 0 ]; then
    echo "!! recomp failed (status $st) -- gen/ is now STALE" >&2
    tail -25 "$OUT/recomp.log" >&2
    exit $st
fi
echo "==> done. Now: tools/win/build-mingw.sh"
