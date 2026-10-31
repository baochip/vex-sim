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
#
# Core variant (VEXSIM_NETLIST): =1 simulates the redacted gate-level
# VexRiscv core from lib/netlist (mounted at /opt/vexsim-lib/netlist)
# instead of the RTL cram_axi.v. The Verilator model cache dir is keyed on
# the variant (build/sim-<view>[-netlist]/gateware), so switching variants
# rebuilds once and each variant stays cached independently.
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

# Startup transparency: every stage announces itself with a wall-clock stamp
# so slow steps (pip installs, verilation, trace copies) are never silent.
# VEXSIM_DEBUG=1 additionally enables `set -x` command tracing.
if [ "${VEXSIM_DEBUG:-0}" = 1 ]; then set -x; fi
log() { echo ">> [$(date +%H:%M:%S)] $*"; }

# --- abort handling ------------------------------------------------------------
# Ctrl+C from an interactive `container-run` arrives as SIGINT (the wrapper
# attaches a TTY so the engine forwards it); `podman stop` / `docker stop`
# arrive as SIGTERM. Vsim is built with the FST-close patch: SIGINT/SIGTERM
# sets an in-model quit flag, the main loop breaks, atexit() closes the
# trace writer (header/hierarchy/seek tables), so the waveform from the
# aborted run is still perfectly readable. We ask for that first, then nudge
# any stuck Litex python / verilation so the pipeline can unwind and the
# trace copy in run_sim() still executes.
ABORTED=0
abort() {
    if [ "$ABORTED" = 1 ]; then exit 130; fi   # second Ctrl+C: leave now
    ABORTED=1
    echo ""
    echo ">> abort requested - stopping (partial waveform still saved)"
    pkill -INT -x Vsim 2>/dev/null || true
    pkill -INT -f 'bao_soc.py|bao_core.py' 2>/dev/null || true
    pkill -x verilate 2>/dev/null || true
    pkill -x make 2>/dev/null || true
    return 0
}
trap abort INT TERM

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
# Core variant: RTL (default) vs redacted gate-level netlist. The model cache
# dir is keyed on it, so flipping --netlist rebuilds the Verilator model once
# and each variant stays cached independently afterwards.
export VEXSIM_NETLIST="${VEXSIM_NETLIST:-0}"
if [ "$VEXSIM_NETLIST" != 0 ]; then
    VIEW_TAG="$VIEW_TAG-netlist"
    export VEXSIM_NETLIST_DIR="${VEXSIM_NETLIST_DIR:-/opt/vexsim-lib/netlist}"
fi
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

# prep: make the toolchain + mounted tree consistent before any build/run.
# The litex+migen stack is BAKED into the image at the pinned gitlink revs,
# so the common path is a fast sanity check, not a per-launch reinstall.
# VEXSIM_FORCE_PREP=1 reinstalls litex+migen from the mounted submodule fork
# (dev flow: editing the Litex/migen forks and iterating without an image
# rebuild). The veril.cpp tracer patch + VexRiscv symlink are re-applied
# every run (cheap, keeps the mounted tree authoritative for the sim core).
prep() {
    check_src
    if [ "${VEXSIM_FORCE_PREP:-0}" = 1 ]; then
        log "prep: FORCE_PREP - reinstalling litex+migen from mounted fork (offline)..."
        # py3.12 tracer fix first (CSR auto-naming dies without it on py>=3.11).
        cp "$PATCHDIR/migen-tracer-py312.py" "$SRC/deps/migen/migen/fhdl/tracer.py"
        /opt/venv/bin/pip install -q --no-index --no-build-isolation --no-deps \
            "$SRC/deps/migen" "$SRC/deps/litex"
        log "prep: litex+migen reinstalled from mounted fork"
    else
        [ -e /opt/venv/.vexsim-prep-ok ] || {
            echo "error: baked litex stack missing in image; rebuild it (./container-run --rebuild)" >&2
            echo "       or set VEXSIM_FORCE_PREP=1 to install from the mounted submodule." >&2; exit 1; }
        log "prep: using image-baked litex+migen"
    fi
    # Golden core complex: the SoC build (and even `bao_soc.py --svd-only`)
    # reads build/gateware/cram_axi.v, so make sure it exists for every mode
    # before any python runs. build/ is a cache, never source: overwriting
    # with the golden rev is deterministic. VEXSIM_BUILD_CORE=1 defers to
    # build_model, which regenerates via bao_core.py instead. In netlist mode
    # the RTL core complex isn't compiled at all, so skip it and check the
    # netlist staging dir instead.
    if [ "$VEXSIM_NETLIST" != 0 ]; then
        [ -d "$VEXSIM_NETLIST_DIR" ] || {
            echo "error: --netlist but no netlist dir at $VEXSIM_NETLIST_DIR" >&2
            echo "       (expected vex-sim lib/netlist staged; container-run" >&2
            echo "        mounts ./lib at /opt/vexsim-lib in --netlist mode)." >&2; exit 1; }
        for f in vex-redacted-clean.v stdcells_rtl.v mbdff.v \
                 rdram1kx32.v rdram128x22.v rdram512x64.v \
                 cram_axi_netlist_wrapper.v; do
            [ -f "$VEXSIM_NETLIST_DIR/$f" ] || {
                echo "error: --netlist missing $f in $VEXSIM_NETLIST_DIR" >&2; exit 1; }
        done
        log "netlist core: $VEXSIM_NETLIST_DIR"
    elif [ "${VEXSIM_BUILD_CORE:-0}" != 1 ] && [ -f /opt/vexsim-golden/cram_axi.v ]; then
        if ! cmp -s /opt/vexsim-golden/cram_axi.v "$VERILATE/build/gateware/cram_axi.v"; then
            mkdir -p "$VERILATE/build/gateware"
            install -m 0644 /opt/vexsim-golden/cram_axi.v "$VERILATE/build/gateware/cram_axi.v"
            log "prep: installed golden core complex cram_axi.v"
        fi
    fi

    # Litex writes csr_svd here, and bao_soc.py/bao_sce.py copy RTL + init
    # artifacts into build/sim/gateware *before* the Builder creates it —
    # a cold tree (bios mode runs bao_soc.py before any model build) dies
    # with FileNotFoundError. build/ is a cache; creating it early is free.
    mkdir -p "$VERILATE/build/software" "$VERILATE/build/sim/gateware"

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
#
# The core complex (cram_axi.v) is FIXED SILICON for this flow's audience
# (firmware developers), so it ships in the image as a golden artifact
# (/opt/vexsim-golden/cram_axi.v, sha256 in VERSIONS) and bao_core.py is NOT
# run. That skips a multi-minute migen/Litex generation step that can never
# produce a different answer. VEXSIM_BUILD_CORE=1 regenerates it from the
# mounted tree (core-complex development flow).
#
# Litex auto-runs Vsim at the end of a successful build; there is no TTY
# in build mode, so kill Vsim the moment it starts -- Litex swallows that
# failure (`except: pass`) and python exits cleanly. The real simulation
# happens via run_sim with console/FST handling.
build_model() {
    cd "$VERILATE"
    mkdir -p build/gateware build/software
    if [ "$VEXSIM_NETLIST" != 0 ]; then
        log "core complex: redacted netlist ($VEXSIM_NETLIST_DIR)"
    elif [ "${VEXSIM_BUILD_CORE:-0}" = 1 ]; then
        log "building core complex from source (bao_core.py)"
        python3 ./bao_core.py
    else
        if [ ! -f /opt/vexsim-golden/cram_axi.v ]; then
            echo "error: golden core complex missing in image; rebuild it" >&2
            echo "       (./container-run --rebuild) or set VEXSIM_BUILD_CORE=1" >&2
            exit 1
        fi
        install -m 0644 /opt/vexsim-golden/cram_axi.v build/gateware/cram_axi.v
        log "core complex: golden cram_axi.v (VEXSIM_BUILD_CORE=1 to regenerate)"
    fi
    log "building SoC defs ($VIEW ${VIEW_ARGS[*]:-})"
    python3 ./bao_soc.py --svd-only --vextype vexi "${VIEW_ARGS[@]}"
    log "verinating + compiling model for view $VIEW_TAG (BIOS=$BIOS)"
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
    # provenance stamp: which core variant this model was verilated from;
    # run_sim rebuilds on mismatch (protects against caches made before the
    # model dir was keyed per variant)
    if [ "$VEXSIM_NETLIST" != 0 ]; then echo netlist > "$MODELDIR/.vexsim-core"; else echo rtl > "$MODELDIR/.vexsim-core"; fi
    log "model ready in $MODELDIR"
}

run_sim() {
    local GW="$MODELDIR"
    if [ ! -x "$GW/obj_dir/Vsim" ]; then
        echo "error: no model for view $VIEW_TAG; building it now"
        build_model
    else
        # Core-variant provenance: rebuild if the cached model was verilated
        # from the other core (RTL vs netlist). Models built before this key
        # existed have no stamp -> treated as stale, rebuilt once.
        local core_want=rtl core_have
        [ "$VEXSIM_NETLIST" != 0 ] && core_want=netlist
        core_have=$(cat "$GW/.vexsim-core" 2>/dev/null || echo missing)
        if [ "$core_have" != "$core_want" ]; then
            log "cached $VIEW_TAG model has core '$core_have', requested '$core_want' - rebuilding"
            build_model
        fi
    fi
    # Run from a writable scratch dir so the trace never races the mount;
    # obj_dir is symlinked (binary is self-contained), the small files
    # (init files, sim_config.js) are copied.
    local RUNDIR; RUNDIR=$(mktemp -d /tmp/vexsim-run.XXXX)
    find "$GW" -maxdepth 1 ! -name obj_dir ! -name "$(basename "$GW")" -exec cp -rL {} "$RUNDIR/" \; 2>/dev/null || true
    ln -s "$GW/obj_dir" "$RUNDIR/obj_dir"
    cd "$RUNDIR"
    rm -f sim.fst
    log "running simulation (console output below; wall-clock cap ${TIMEOUT_SECS}s)"
    echo ">> Ctrl+C aborts; the waveform is still closed + saved"
    # `script -qec` gives Vsim a pty so its $display output is line-buffered:
    # without it console.log only fills in 4 KiB blocks and looks frozen, and
    # a timeout kill would lose the buffer. stdin /dev/null keeps Litex
    # modules off the tty; TTY input isn't needed.
    # Backgrounded so the INT/TERM trap runs *during* the run (bash defers
    # traps around foreground children, and with job control off the pipeline
    # shares our process group): abort() SIGINTs Vsim directly, the patched
    # trace handler closes the FST, then the trace copy below still runs.
    # script's own stdin is /dev/null: with `podman run -t` an open attach
    # stream makes script hang after Vsim exits (it drains stdin to EOF).
    timeout "$TIMEOUT_SECS" script -qec './obj_dir/Vsim < /dev/null' /dev/null < /dev/null 2>&1 | tee "$WORK/console.log" & SIMPID=$!
    wait "$SIMPID" 2>/dev/null || true
    wait "$SIMPID" 2>/dev/null || true   # 1st wait returns early on abort; 2nd reaps
    if [ -f sim.fst ]; then
        cp -f sim.fst "$WORK/sim.fst"
        log "waveform written to $WORK/sim.fst ($(du -h "$WORK/sim.fst" | cut -f1))"
    fi
    if [ -f "$WORK/console.log" ]; then
        n=$(grep -c '\[duart\]' "$WORK/console.log" || true)
        log "duart console lines captured: $n"
    fi
    rm -rf "$RUNDIR"
}

case "$MODE" in
    sim)
        prep
        run_sim
        if [ "$ABORTED" = 1 ]; then exit 130; fi
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
        log "regenerating boot-memory init from $BIOS"
        python3 ./bao_soc.py --svd-only --vextype vexi "${VIEW_ARGS[@]}" --bios "$BIOS"
        mkdir -p "$MODELDIR"
        cp -f build/gateware/reram_mem.init "$MODELDIR/reram_mem.init"
        run_sim
        if [ "$ABORTED" = 1 ]; then exit 130; fi
        ;;
    bash|sh)
        exec "$MODE"
        ;;
    *)
        echo "usage: entrypoint [sim|build|bios|bash]  (VEXSIM_VIEW, VEXSIM_BIOS, VEXSIM_TIMEOUT)" >&2
        exit 1
        ;;
esac
