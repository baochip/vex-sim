# vex-sim

Containerized [Verilator](https://verilator.org/) simulation of the
baochip-1x **"bao" SoC** (VexRiscv "vexi" core, Litex fabric) running the
**nto-tests** bare-metal test firmware. Produces an FST waveform (`sim.fst`)
and captures the simulated DUAL UART console to `console.log` — with nothing
to install on the host except podman or docker.

Modeled on the [bio-sim](../bio-sim) container strategy: the toolchain lives
in the image, your workspace is mounted at runtime, and waveforms are
ordinary files.

## Quick start

```sh
git submodule update --init --recursive   # populate baochip-1x (+ its deps)
./container-run                           # builds the image on first use
                                          # (~10 min toolchain), then the
                                          # sim model (first run: 21 s on a
                                          # 32-core host, scales with cores),
                                          # cached afterwards, then simulates
```

Outputs land in `./out/`:

- `sim.fst` — full waveform (open with `gtkwave sim.fst`, or any FST viewer)
- `console.log` — captured `[duart]` console output from the firmware

The simulation is compute-bound (~5 CPU cores). The firmware boots, runs the
reset-value + bio test suites, then signals `finisher.v` to end the run
early; the whole sim takes seconds once the model exists. The waveform cap
is `VEXSIM_TIMEOUT` wall-clock seconds (default 1800) — the FST closes
cleanly either way (header/hierarchy/seek tables are written at exit).
Ctrl+C during a run aborts it the same clean way: the model stops, and the
partial waveform is still closed and saved to `out/sim.fst` (exit 130).
A second Ctrl+C leaves immediately.

## Layout

```
vex-sim/
+-- baochip-1x/         # git submodule: the SoC + sim sources (mounted, not baked)
|   +-- verilate/       #   Litex build scripts (bao_soc.py, bao_core.py, ...)
|   +-- verilate/build/ #   model cache — persists here across runs
+-- golden/cram_axi.v   # golden core complex (fixed silicon; baked into image)
+-- firmware/boot.bin   # bundled default firmware (prebuilt nto-tests image)
+-- out/                # sim.fst, console.log, your own boot.bin
+-- patches/            # runtime patches (migen tracer py3.12, FST-close veril.cpp)
+-- Dockerfile          # toolchain image
+-- container-run       # wrapper (podman/docker)
```

The image carries the **fixed toolchain**: Verilator 5.052 (source build),
the Litex stack (migen + litex at the pinned baochip gitlink revs, tracer
fix applied) installed into a venv from git, and the **golden core complex**
(`cram_axi.v`, generated once by `bao_core.py` from the pinned RTL). The
SoC "views" — the part you iterate on — are NOT baked: the `baochip-1x`
submodule tree is bind-mounted read-write at `/opt/baochip-1x`, and the
Verilator model builds INTO that tree (per-view cache under
`verilate/build/sim-<view>/`). Consequences:

- edit any SoC-level RTL / build script under `baochip-1x/` and rerun — no
  image rebuild; the model build re-verilates automatically,
- the model cache (`baochip-1x/verilate/build/`) survives between runs and
  lives with your checkout (~900 MB; `make distclean` removes it),
- starting a container is instant: no per-launch pip install, and the core
  complex is installed from the golden artifact instead of regenerated
  (~2 min of `bao_core.py` skipped),
- dev overrides: `VEXSIM_FORCE_PREP=1` reinstalls litex/migen from the
  mounted `deps/` forks (editing the forks without image rebuilds);
  `VEXSIM_BUILD_CORE=1` regenerates `cram_axi.v` from the mounted RTL tree.

## How it works

```
container-run ──podman run -v ./out:/work -v ./baochip-1x:/opt/baochip-1x──▶ entrypoint
   prep: use image-baked litex/migen; install golden cram_axi.v;
         re-apply veril.cpp patch; VexRiscv symlink
   build (only if the model for this view is missing or `build` mode):
     cram_axi.v (golden) ; bao_soc.py → sim.v + Verilator obj_dir/Vsim
   run:  obj_dir/Vsim  ├─ stdout ─▶ /work/console.log
                        └─ sim.fst ─▶ /work/sim.fst
```

Exact tool revisions in `VERSIONS`. Two patches make the flow work (see
`patches/`, never committed to the submodule): a migen bytecode-tracer fix
for Python 3.12, baked into the image's migen at build time; and a
replacement litex `veril.cpp` that closes the FST writer via `atexit` +
SIGTERM/SIGINT/SIGHUP, re-applied to the venv at every container start —
upstream never calls `Writer::close()`, so wave files would lack their
header/hierarchy/seek tables after `$finish` or a timeout kill.

## Views (SoC definition)

`--view` selects which SoC definition builds the model (each view caches its
own model under `verilate/build/sim-<view>/`):

| `--view` | builds | status |
|---|---|---|
| `bao_soc.py` (default) | main bao SoC | working |
| `bao_udma.py` | UDMA variant (`bao_soc.py --udma`) | **broken upstream**: `deps/soc_oss/udma_adapter.py` copies `./soc_oss/rtl/common/io_interface_def_v0.1.sv`, a tree not present in the pinned checkout (upstream `verilate.sh` notes udma is "once that's debugged and working again") |
| `bao_sce.py` | SCE/crypto variant (`bao_soc.py --sce`) | working (needs the `soc_oss` open-source bus bridges + the `ahbs()` interface-instance fix, both in the pinned tree) |

The sce view originally failed in two ways: it pulled closed Arm
CMSDK models from `/opt/cram-nto` (not redistributable), and once those
were replaced by the in-tree `oss_*` bridge re-implementations, Verilator
aborted with `Wire inputs its own output, creating circular logic (wire
x=x)` on `sceahbif.haddr`. Root cause: `deps/soc_oss/sce_adapter.sv`
declared `ahbif #(...) ahbs;` — a parenless interface-typed *variable*
(illegal SystemVerilog; IEEE 2632.2-2003 requires an instantiation).
V3Const inlines the pass-through `ahb_thru` onto that variable and the
slave-side pin `ahbslave.haddr` resolves onto the master's own signal.
Fix: `ahbif #(...) ahbs();` (an instance). Same latent bug fixed
proactively in `deps/soc_oss/soc_ifsub_udma.sv`.

```sh
./container-run --view bao_sce.py build    # build + run the SCE model
./container-run --view bao_udma.py build   # attempt the udma model
```

## Options

| Env var | Default | Meaning |
|---|---|---|
| `VEXSIM_VIEW` | `bao_soc.py` | SoC definition (see table) |
| `VEXSIM_TIMEOUT` | `1800` | wall-clock cap (s) on the simulation run |
| `VEXSIM_BIOS` | `/opt/firmware/boot.bin` | firmware image (`bios` mode) |
| `VEXSIM_THREADS` | `5` | Verilator `--threads` (model build) |
| `VEXSIM_JOBS` | `20` | C++ compile parallelism (model build) |
| `VEXSIM_TRACE_START/END` | `0` / `200000000000` | trace window (ps) |
| `VEXSIM_CPUS` | — | pass `--cpus` to the engine |
| `VEXSIM_DEBUG` | — | `1`: `set -x` command tracing inside the entrypoint (every startup step, timestamped) |
| `VEXSIM_FORCE_PREP` | — | `1`: reinstall litex/migen from the mounted `baochip-1x/deps/` forks (dev flow: editing the forks without image rebuilds) |
| `VEXSIM_BUILD_CORE` | — | `1`: regenerate the core complex (`bao_core.py`) from the mounted RTL instead of using the golden `cram_axi.v` |
| `VEXSIM_NETWORK` | `none` | container network for the run (sim needs none; set `slirp`/`bridge` only if extending the flow to need net) |
| `VEXSIM_BUILD_ISOLATION` | — | e.g. `chroot` — image builds on rootless podman hosts without a systemd user session (runc can't create cgroup scopes there; only `podman build` is affected, `podman run` works) |
| `CONTAINER_ENGINE` | auto | `podman` or `docker` |

```sh
./container-run --rebuild          # rebuild the image after editing Dockerfile
./container-run build              # force model re-verification/build
./container-run bash              # shell inside the image
VEXSIM_TIMEOUT=600 ./container-run
```

## Firmware

The image bundles a prebuilt nto-tests `boot.bin`
(`firmware/boot.bin`, sha256 in `VERSIONS`) including a sim early-quit hook
so runs end at `$finish` in seconds. To run your own firmware, build it
(anywhere with rust + riscv-none-elf binutils; the submodule has the
sources):

```sh
cd baochip-1x/deps/nto-tests          # or a clone at the pinned rev
cargo xtask boot-image --no-default-features \
    --feature fast-fclk --feature quirks-pll --feature aes-zkn \
    --feature bio-mul --feature reset-value-tests --feature bio-tests
python3 ./merge_cm7.py --rv32=rv32.bin --cm7=cm7/mbox.bin --out-file=boot.bin
cp boot.bin ../../../out/boot.bin
cd ../../.. && ./container-run bios   # ~2 min: regenerates boot-memory init,
                                      # reuses the cached model (no re-verify)
```

Or skip the `cp` and name the image directly — any host path works (it is
staged into `out/` for the mount), and it composes with `--view`:

```sh
./container-run bios /path/to/boot.bin
./container-run --bios /path/to/boot.bin --view bao_sce.py
```

(`baochip-1x/deps/nto-tests` ships SVDs missing the AORAM region that
utralib's build.rs needs; apply `patches/daric-svd-aoram-region.patch`
before building. Not needed for the bundled image.)

## Native (no container)

The image merely automates what these host tools do; if you have them all
(Verilator 5.052, the Litex fork venv, rust + riscv-none-elf binutils):

```sh
cd baochip-1x/verilate
./verilate.sh                      # testbench target; see script for variants
```

## Known limitations

- `bao_udma.py` view: broken in the pinned sources (the `soc_oss/rtl`,
  `soc_oss_tapeout`, and `candidate` RTL trees referenced by
  `deps/soc_oss/udma_adapter.py` are absent from the submodule). The one
  bug that *was* fixable there — the same parenless `ahbs` interface
  variable — is fixed in `soc_ifsub_udma.sv`, but the missing trees block
  the view until they are published.
- `verilate.sh -t xous` (Xous OS boot simulation) is **not** wired into the
  container yet. Follow-on work: `cargo xtask bao1x-sim` + `finisher.v`
  Xous define.
- Image build needs network (apt, pip git wheels, Verilator tarball). The
  simulation itself never touches the network.
- The DUT is the full SoC; a full trace is large (15 MB after early quit;
  multi-GB at the 1800 s timeout). `VEXSIM_TRACE_START/END` trim the window.
