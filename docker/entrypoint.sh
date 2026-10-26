#!/usr/bin/env bash
# vex-sim container entrypoint.
#
# The image carries ONLY the toolchain (verilator, Litex venv skeleton);
# the baochip-1x sources are bind-mounted at $VEXSIM_SRC (host
# ./baochip-1x submodule) and the model is built INTO that mounted tree,
# so build caches survive between runs and live with your checkout.
#
# Modes:
#   sim     (default) build the model if needed, then run it; writes
#                     sim.fst + console.log into /work
#   build   only (re)build the Verilator model for the selected view
#   bios    fast firmware swap: regenerate boot-memory init from $BIOS
#                     (mounted at /work/fw.bin) and run the cached model.
#                     No re-verification; ~2 min of Litex python.
#   bash    shell for debugging
#
# View selection (VEXSIM_VIEW): which SoC definition drives the build.
#   bao_soc.py   (default) main bao SoC          -> bao_soc.py
#   bao_udma.py            UDMA variant          -> bao_soc.py --udma
#   bao_sce.py             SCE variant           -> bao_soc.py --sce
# bao_udma.py / bao_sce.py are module-only (no __main__); bao_soc.py
# dispatches to them via --udma / --sce, so the view name maps to a flag.
set -euo pipefail

SRC="${VEXSIM_SRC:-/opt/baochip-1x}"
VERILATE="$SRC/verilate"
WORK=/work
TIMEOUT_SECS="${VEXSIM_TIMEOUT:-1800}"
BIOS="${VEXSIM_BIOS:-/opt/firmware/boot.bin}"
THREADS="${VEXSIM_THREADS:-5}"
JOBS="${VEXSIM_JOBS:-20}"
TRACE_START="${VEXSIM_TRACE_START:-0}"
TRACE_END="${VEXSIM_TRACE_END:-200000000000}"
MODE="${1:-sim}"
[ $# -gt 0 ] && shift
EXTRA_ARGS=("$@")

# --- view selection ----------------------------------------------------------
VIEW="${VEXSIM_VIEW:-bao_soc.py}"
VIEW="${VIEW#./}"
case "$VIEW" in
    bao_soc.py|soc)  VIEW=bao_soc.py;  VIEW_ARGS=()          ;;
    bao_udma.py|udma) VIEW=bao_udma.py; VIEW_ARGS=(--udma)    ;;
    bao_sce.py|sce)   VIEW=bao_sce.py;  VIEW_ARGS=(--sce)     ;;
    *) echo "error: unknown view '$VIEW' (bao_soc.py|bao_udma.py|bao_sce.py)" >&2; exit 1 ;;
esac
VIEW_TAG=soc; [ "$VIEW" = bao_udma.py ] && VIEW_TAG=udma; [ "$VIEW" = bao_sce.py ] && VIEW_TAG=sce
MODELDIR="$VERILATE/build/sim-$VIEW_TAG/gateware"

PATCHDIR=/opt/vexsim-patches

check_src() {
    if [ ! -d "$VERILATE" ] || [ ! -f "$VERILATE/bao_soc.py" ]; then
        echo "error: no baochip-1x tree mounted at $SRC" >&2
        echo "       run via ./container-run (it bind-mounts ./baochip-1x)," >&2
        echo "       or set VEXSIM_SRC to a baochip-1x checkout." >&2
        exit 1
    fi
    if [ ! -e "$SRC/deps/migen/setup.py" ] || [ ! -e "$SRC/deps/litex/setup.py" ]; then
        echo "error: submodule deps not initialized in $SRC" >&2
        echo "       host: git submodule update --init --recursive" >&2
        exit 1
    fi
}

# prep: make the mounted tree usable with the image toolchain. Idempotent;
# runs once per container invocation before any build/run.
prep() {
    check_src
    # migen py3.12 tracer fix (CSR auto-naming dies without it on py>=3.11).
    # The submodule checkout is pristine; overwrite is identity when patched.
    if ! cmp -s "$PATCHDIR/migen-tracer-py312.py" "$SRC/deps/migen/migen/fhdl/tracer.py"; then
        cp "$PATCHDIR/migen-tracer-py312.py" "$SRC/deps/migen/migen/fhdl/tracer.py"
    fi
    # litex + migen from the mounted fork (offline: venv already has all deps).
    /opt/venv/bin/pip install -q --no-index --no-build-isolation --no-deps \
        "$SRC/deps/migen" "$SRC/deps/litex"
    # litex's sim-core tracer (veril.cpp) never closes the FST/VCD writer:
    # header/hierarchy/seek tables are only emitted at close(), so a run
    # ended by $finish or a timeout kill leaves an unparseable trace. Our
    # veril.cpp registers litex_sim_tracer_close() with atexit +
    # SIGINT/SIGTERM/SIGHUP handlers.
    cp "$PATCHDIR/veril-fst-close.cpp" \
        /opt/venv/lib/python3.12/site-packages/litex/build/sim/core/veril.cpp
    # litex's vexriscv_axi core parses VexRiscv/GenCramSoC.scala via a
    # venv-relative path; point it into the mounted tree.
    ln -sfn "$SRC/VexRiscv" /opt/venv/lib/VexRiscv
}

# build_model: core complex + SoC + Verilator compile into MODELDIR.
# Litex auto-runs Vsim at the end of a successful build; there is no TTY
# in build mode, so kill Vsim the moment it starts -- Litex swallows that
# failure (`except: pass`) and python exits cleanly. The real simulation
# happens via run_sim with console/FST handling.
build_model() {
    cd "$VERILATE"
    mkdir -p build/gateware build/software
    echo ">> building core complex (bao_core.py)"
    python3 ./bao_core.py
    echo ">> building SoC defs ($VIEW ${VIEW_ARGS[*]:-})"
    python3 ./bao_soc.py --svd-only --vextype vexi "${VIEW_ARGS[@]}"
    echo ">> verinating + compiling model for view $VIEW_TAG (BIOS=$BIOS)"
    ( timeout 6h python3 ./bao_soc.py --vextype vexi --speed normal \
        "${VIEW_ARGS[@]}" \
        --bios "$BIOS" --boot-offset 0x000000 \
        --gtkwave-savefile --threads "$THREADS" --jobs "$JOBS" \
        --trace --trace-start "$TRACE_START" --trace-end "$TRACE_END" \
        --trace-fst --non-interactive \
        "${EXTRA_ARGS[@]}" & pid=$!; \
      while kill -0 $pid 2>/dev/null; do \
        pkill -x Vsim 2>/dev/null && break; sleep 2; \
      done ; wait $pid ; true )
    if [ ! -x build/sim/gateware/obj_dir/Vsim ]; then
        echo "error: build failed - no Vsim produced" >&2
        exit 1
    fi
    rm -f build/sim/gateware/sim.fst
    # mirror the per-view model into its cache dir (hardlinks; same fs)
    rm -rf "$MODELDIR"
    mkdir -p "$(dirname "$MODELDIR")"
    cp -al build/sim/gateware "$MODELDIR" 2>/dev/null || cp -a build/sim/gateware "$MODELDIR"
    echo ">> model ready in $MODELDIR"
}

run_sim() {
    local GW="$MODELDIR"
    if [ ! -x "$GW/obj_dir/Vsim" ]; then
        echo "error: no model for view $VIEW_TAG; building it now"
        build_model
    fi
    # Run from a writable scratch dir so the trace never races the mount;
    # obj_dir is symlinked (binary is self-contained), the small files
    # (init files, sim_config.js) are copied.
    local RUNDIR; RUNDIR=$(mktemp -d /tmp/vexsim-run.XXXX)
    find "$GW" -maxdepth 1 ! -name obj_dir ! -name "$(basename "$GW")" -exec cp -rL {} "$RUNDIR/" \; 2>/dev/null || true
    ln -s "$GW/obj_dir" "$RUNDIR/obj_dir"
    cd "$RUNDIR"
    rm -f sim.fst
    echo ">> running simulation (console output below; wall-clock cap ${TIMEOUT_SECS}s)"
    # `script -qec` gives Vsim a pty so its $display output is line-buffered:
    # without it console.log only fills in 4 KiB blocks and looks frozen, and
    # a timeout kill would lose the buffer. stdin /dev/null keeps Litex
    # modules off the tty; TTY input isn't needed.
    timeout "$TIMEOUT_SECS" script -qec './obj_dir/Vsim < /dev/null' /dev/null 2>&1 | tee "$WORK/console.log" || true
    if [ -f sim.fst ]; then
        cp -f sim.fst "$WORK/sim.fst"
        echo ">> waveform written to $WORK/sim.fst ($(du -h "$WORK/sim.fst" | cut -f1))"
    fi
    if [ -f "$WORK/console.log" ]; then
        n=$(grep -c '\[duart\]' "$WORK/console.log" || true)
        echo ">> duart console lines captured: $n"
    fi
    rm -rf "$RUNDIR"
}

case "$MODE" in
    sim)
        prep
        run_sim
        ;;
    build)
        prep
        build_model
        ;;
    bios)
        # Fast firmware swap: boot.bin only enters the model through the
        # $readmemb init file at sim startup, so no re-verilation is needed.
        # Regenerate reram_mem.init from $BIOS with Litex (python-only) and
        # run the cached model.
        prep
        if [ ! -f "$BIOS" ]; then
            echo "error: BIOS image not found at $BIOS (put it at out/boot.bin" >&2
            echo "       and run with VEXSIM_BIOS=/work/fw.bin)" >&2
            exit 1
        fi
        cd "$VERILATE"
        echo ">> regenerating boot-memory init from $BIOS"
        python3 ./bao_soc.py --svd-only --vextype vexi "${VIEW_ARGS[@]}" --bios "$BIOS"
        mkdir -p "$MODELDIR"
        cp -f build/gateware/reram_mem.init "$MODELDIR/reram_mem.init"
        run_sim
        ;;
    bash|sh)
        exec "$MODE"
        ;;
    *)
        echo "usage: entrypoint [sim|build|bios|bash]  (VEXSIM_VIEW, VEXSIM_BIOS, VEXSIM_TIMEOUT)" >&2
        exit 1
        ;;
esac
