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
                                          # sim model (~30-45 min first run,
                                          # cached afterwards), then simulates
```

Outputs land in `./out/`:

- `sim.fst` — full waveform (open with `gtkwave sim.fst`, or any FST viewer)
- `console.log` — captured `[duart]` console output from the firmware

The simulation is compute-bound (~5 CPU cores). The firmware boots, runs the
reset-value + bio test suites, then signals `finisher.v` to end the run
early; the whole sim takes seconds once the model exists. The waveform cap
is `VEXSIM_TIMEOUT` wall-clock seconds (default 1800) — the FST closes
cleanly either way (header/hierarchy/seek tables are written at exit).

## Layout

```
vex-sim/
+-- baochip-1x/         # git submodule: the SoC + sim sources (mounted, not baked)
|   +-- verilate/       #   Litex build scripts (bao_soc.py, bao_core.py, ...)
|   +-- verilate/build/ #   model cache — persists here across runs
+-- firmware/boot.bin   # bundled default firmware (prebuilt nto-tests image)
+-- out/                # sim.fst, console.log, your own boot.bin
+-- patches/            # runtime patches (migen tracer py3.12, FST-close veril.cpp)
+-- Dockerfile          # toolchain-only image
+-- container-run       # wrapper (podman/docker)
```

The image carries **only the toolchain** (Verilator 5.052 source build +
Litex venv skeleton + patches). The `baochip-1x` submodule tree is
bind-mounted read-write at `/opt/baochip-1x`; the entrypoint installs the
forked `migen`/`litex` from the mounted tree into the venv (offline), then
builds and runs. Consequences:

- edit any RTL / build script under `baochip-1x/` and rerun — no image
  rebuild; the model build re-verilates automatically,
- the model cache (`baochip-1x/verilate/build/`) survives between runs and
  lives with your checkout (~900 MB; `make distclean` removes it),
- image rebuilds are fast; only the toolchain pins force one.

## How it works

```
container-run ──podman run -v ./out:/work -v ./baochip-1x:/opt/baochip-1x──▶ entrypoint
   prep: pip-install mounted migen/litex, apply patches/ (tracer, veril.cpp)
   build (only if the model for this view is missing or `build` mode):
     bao_core.py → cram_axi.v ; bao_soc.py → sim.v + Verilator obj_dir/Vsim
   run:  obj_dir/Vsim  ├─ stdout ─▶ /work/console.log
                        └─ sim.fst ─▶ /work/sim.fst
```

Exact tool revisions in `VERSIONS`. Two runtime patches make the flow work
(see `patches/`, applied at container start, never committed to the
submodule): a migen bytecode-tracer fix for Python 3.12, and a replacement
litex `veril.cpp` that closes the FST writer via `atexit` +
SIGTERM/SIGINT/SIGHUP — upstream never calls `Writer::close()`, so wave
files would lack their header/hierarchy/seek tables after `$finish` or a
timeout kill.

## Views (SoC definition)

`--view` selects which SoC definition builds the model (each view caches its
own model under `verilate/build/sim-<view>/`):

| `--view` | builds | status |
|---|---|---|
| `bao_soc.py` (default) | main bao SoC | working |
| `bao_udma.py` | UDMA variant (`bao_soc.py --udma`) | **broken upstream**: `deps/soc_oss/udma_adapter.py` copies `./soc_oss/rtl/common/io_interface_def_v0.1.sv`, a tree not present in the pinned checkout (upstream `verilate.sh` notes udma is "once that's debugged and working again") |
| `bao_sce.py` | SCE variant (`bao_soc.py --sce`) | **needs closed ARM CM IP**: verilation stops on missing `/opt/cram-nto/ips/ambabuilder/...` Arm CMSDK sources, not redistributable |

```sh
./container-run --view bao_udma.py build     # attempt the udma model
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

- `bao_udma.py` / `bao_sce.py` views: see the table above — broken in the
  pinned sources (missing `soc_oss/rtl` tree; missing licensed Arm IP).
- `verilate.sh -t xous` (Xous OS boot simulation) is **not** wired into the
  container yet. Follow-on work: `cargo xtask bao1x-sim` + `finisher.v`
  Xous define.
- Image build needs network (apt, pip git wheels, Verilator tarball). The
  simulation itself never touches the network.
- The DUT is the full SoC; a full trace is large (15 MB after early quit;
  multi-GB at the 1800 s timeout). `VEXSIM_TRACE_START/END` trim the window.
