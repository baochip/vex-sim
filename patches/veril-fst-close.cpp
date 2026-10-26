/* Copyright (C) 2017 LambdaConcept */
/* FST/VCD close patch (vex-sim): litex's sim-core never closes the trace
 * writer, so the wave file's header/hierarchy/seek tables (written at
 * close()) are missing whenever the simulation ends via $finish-without-
 * main-return, a timeout kill, or a signal. This patch:
 *   - closes the tracer from atexit() (covers $finish -> loopbreak -> main
 *     return, and normal exit),
 *   - SIGINT/SIGTERM/SIGHUP only raise a flag (async-signal-safe: the old
 *     close-in-handler design deadlocked against Verilator's trace mutex
 *     when --threads > 1); the event loop notices through
 *     litex_sim_got_finish(), breaks cleanly, and atexit() closes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdint.h>
#include "Vsim.h"
#include "verilated.h"
#ifdef TRACE_FST
#include "verilated_fst_c.h"
#else
#include "verilated_vcd_c.h"
#endif

#ifdef TRACE_FST
VerilatedFstC* tfp;
#else
VerilatedVcdC* tfp;
#endif
uint64_t tfp_start;
uint64_t tfp_end;
uint64_t main_time = 0;
Vsim *g_sim = nullptr;

static bool tfp_closed = false;
static volatile sig_atomic_t quit_request = 0;
extern "C" void litex_sim_tracer_close(void)
{
  if (tfp_closed || tfp == nullptr) return;
  tfp_closed = true;
  tfp->close();
  tfp = nullptr;
}
static void tracer_signal_handler(int)
{
  quit_request = 1;  /* async-signal-safe; loop exits via got_finish() */
}

extern "C" void litex_sim_eval(void *vsim, uint64_t time_ps)
{
  Vsim *sim = (Vsim*)vsim;
  sim->eval();
  main_time = time_ps;
}

extern "C" void litex_sim_init_cmdargs(int argc, char *argv[])
{
  Verilated::commandArgs(argc, argv);
}

extern "C" void litex_sim_init_tracer(void *vsim, long start, long end)
{
  Vsim *sim = (Vsim*)vsim;
  tfp_start = start;
  tfp_end = end >= 0 ? end : UINT64_MAX;
  Verilated::traceEverOn(true);
#ifdef TRACE_FST
      tfp = new VerilatedFstC;
      sim->trace(tfp, 99);
      tfp->open("sim.fst");
#else
      tfp = new VerilatedVcdC;
      sim->trace(tfp, 99);
      tfp->open("sim.vcd");
#endif
  tfp->set_time_unit("1ps");
  tfp->set_time_resolution("1ps");
  g_sim = sim;
  atexit(litex_sim_tracer_close);
  signal(SIGINT,  tracer_signal_handler);
  signal(SIGTERM, tracer_signal_handler);
  signal(SIGHUP,  tracer_signal_handler);
}

extern "C" void litex_sim_tracer_dump()
{
  static int last_enabled = 0;
  bool dump_enabled = true;

  if (g_sim != nullptr) {
    dump_enabled = g_sim->sim_trace != 0 ? true : false;
    if (last_enabled == 0 && dump_enabled) {
      printf("<DUMP ON>");
      fflush(stdout);
    } else if (last_enabled == 1 && !dump_enabled) {
      printf("<DUMP OFF>");
      fflush(stdout);
    }
    last_enabled = (int) dump_enabled;
  }

  if (dump_enabled && tfp_start <= main_time && main_time <= tfp_end) {
    tfp->dump((vluint64_t) main_time);
  }
}

extern "C" int litex_sim_got_finish()
{
  if (quit_request) return 1;
  return Verilated::gotFinish();
}

#if VM_COVERAGE
extern "C" void litex_sim_coverage_dump()
{
  VerilatedCov::write("sim.cov");
}
#endif

double sc_time_stamp()
{
  return main_time;
}
