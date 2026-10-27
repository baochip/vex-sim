# vex-sim: containerized VexRiscv (baochip-1x "bao" SoC) Verilator simulation.
#
# Toolchain-only image: verilator (source build) + the Litex stack skeleton.
# The baochip-1x sources are NOT baked in -- they are bind-mounted at runtime
# from the ./baochip-1x submodule, and the Verilator model is built INTO that
# mounted tree (build/ dirs), so caches persist across runs and source edits
# take effect without rebuilding this image.
#
# Pinned revisions match the verified native build (see VERSIONS).

FROM docker.io/library/ubuntu:24.04 AS sim

ENV DEBIAN_FRONTEND=noninteractive
# Package set verified natively: build-essential/perl/python3 for the
# Litex sim core + verilator source build; libevent/libjson-c for the Litex
# sim-core modules (serial2console etc.); liblz4+zlib for verilator 5.052's
# fstcpp FST writer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make g++ gcc perl python3 python3-venv python3-dev \
        autoconf automake flex bison m4 libfl-dev \
        git curl ca-certificates time procps help2man \
        libevent-dev libjson-c-dev zlib1g-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Verilator built from source (5.052): apt's 5.020 predates features this
# flow is verified against (fstcpp FST writer etc.).
ARG VERILATOR_VER=5.052
RUN curl -fsSL "https://github.com/verilator/verilator/archive/refs/tags/v${VERILATOR_VER}.tar.gz" \
      -o /tmp/v.tgz && mkdir -p /opt/vsrc && \
    python3 -c "import tarfile; tarfile.open('/tmp/v.tgz').extractall('/opt/vsrc', filter='data')" && \
    cd /opt/vsrc/verilator-${VERILATOR_VER} && \
    autoconf && ./configure --prefix=/opt/verilator && \
    make -j"$(nproc)" && make install && rm -rf /tmp/v.tgz /opt/vsrc
ENV PATH=/opt/verilator/bin:$PATH

# --- Litex venv skeleton -------------------------------------------------------
# All Litex deps EXCEPT migen/litex themselves (those come from the mounted
# submodule fork at container start, offline -- see entrypoint prep). The
# pythondata-* repos are fetched as pip wheels at image build; pyvcd,
# pyserial etc. are Litex sim-core runtime imports.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    /opt/venv/bin/pip install --no-cache-dir \
        git+https://github.com/litex-hub/pythondata-misc-tapcfg.git \
        git+https://github.com/litex-hub/pythondata-software-compiler_rt.git \
        git+https://github.com/litex-hub/pythondata-software-picolibc.git \
        git+https://github.com/litex-hub/pythondata-cpu-vexriscv.git \
        pyvcd pyserial requests packaging colorama Markdown jinja2

ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH

# --- runtime patches staged for the entrypoint --------------------------------
#   migen-tracer-py312.py : upstream migen fix for Python 3.11+ bytecode
#       tracing (get_var_name must skip CACHE/EXTENDED_ARG opcodes and index
#       STORE_DEREF against co_nlocals). Applied to the mounted deps/migen at
#       container start; without it Litex CSR auto-naming dies on py3.12 with
#       "Cannot extract CSR name from code".
#   veril-fst-close.cpp   : replacement litex sim-core veril.cpp whose
#       litex_sim_tracer_close() is wired to atexit + SIGINT/SIGTERM/SIGHUP,
#       so the FST writer flushes its header/hierarchy/seek tables on $finish
#       and on timeout kills (upstream never closes -> unparseable trace).
#       Overwrites the venv copy at container start, BEFORE any verilator
#       build compiles veril.o.
COPY patches/migen-tracer-py312.py patches/veril-fst-close.cpp /opt/vexsim-patches/

# --- default firmware ----------------------------------------------------------
# Prebuilt nto-tests test firmware (boot.bin: rv32 test image + merged CM7
# mailbox blob, incl. the sim early-quit hook). Rebuild it yourself from
# baochip-1x/deps/nto-tests with:
#   cargo xtask boot-image --no-default-features \
#     --feature fast-fclk --feature quirks-pll --feature aes-zkn \
#     --feature bio-mul --feature reset-value-tests --feature bio-tests
#   python3 ./merge_cm7.py --rv32=rv32.bin --cm7=cm7/mbox.bin --out-file=boot.bin
# and drop it in out/boot.bin, then:  ./container-run bios
COPY firmware/boot.bin /opt/firmware/boot.bin

# --- runtime -------------------------------------------------------------------
# /opt/baochip-1x is the bind-mount target for the host submodule tree;
# /work is the user's output dir (sim.fst + console.log land there).
WORKDIR /work
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sim"]
