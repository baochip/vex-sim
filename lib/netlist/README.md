# lib/netlist — redacted-VexRiscv netlist view (`--netlist`)

Everything needed to simulate the taped-out VexRiscv core complex as a
gate-level netlist instead of the RTL `cram_axi.v`. Selected by
`./container-run --netlist`; the default stays RTL.

All files here are open/redistributed-safe: the redacted netlist contains
**no** proprietary ARM cells (the CM7 CPU is absent from this hierarchy;
std cells are replaced by the behavioral RTL models), and no transistor
or timing models ship in this tree.

| file | role |
|---|---|
| `vex-redacted-clean.v` | redacted gate-level netlist of the core complex (module `cram_axi_I_rbif_..._AW_9_DW_64`), produced by `netlist-script/autoredact.py` from `vex.json` + `master_mapping.json` |
| `stdcells_rtl.v` | behavioral RTL models of the standard cells the netlist instantiates (117 of 238 used) |
| `mbdff.v` | RTL models of the 2/4-bit retention register cells |
| `rdram1kx32.v` | OSS behavioral model of the ARM 22ULP macro (1024x32 + wenb), differential-verified against the proprietary UD model |
| `rdram128x22.v` | ... (128x22, full-word writes) |
| `rdram512x64.v` | ... (512x64, full-word writes) |
| `cram_axi_sig.v` | RTL method signature of `cram_axi` (with SV `rbif` interfaces) — reference for wrapper generation |
| `cram_axi_netlist_wrapper.v` | generated scalar-only wrapper: module `cram_axi` with exactly the golden RTL core's 156 ports, instantiating the netlist top. rbif_* netlist ports are silicon DFT/trim-only (functional clocks come from the internal ICG/CTS tree) and are tied/parked. |

Do not edit the wrapper by hand; regenerate with `gen_netlist_wrapper.py`
(from the `netlist-script/` tools tree; paths relative to `vex-sim/`):

```sh
path/to/netlist-script/gen_netlist_wrapper.py \
    --sig lib/netlist/cram_axi_sig.v \
    --netlist lib/netlist/vex-redacted-clean.v --wrapper-name cram_axi \
    --scalar-only --out lib/netlist/cram_axi_netlist_wrapper.v
```

The netlist's macros (`rdram*`) are blackbox leaves for yosys; they are
*not* in `vex-redacted-clean.v`, which is why the three behavioral models
must compile alongside it.
