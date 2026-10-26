# vex-sim: thin wrapper over container-run (podman/docker auto-detected)
# Sources: ./baochip-1x (git submodule); model cache lives in its verilate/build.
IMAGE ?= vex-sim

.PHONY: help build rebuild sim build-model shell clean

help:
	@echo "make build       - (re)build the container image"
	@echo "make sim         - run the testbench simulation (outputs in ./out)"
	@echo "make build-model - (re)build the Verilator model only"
	@echo "make rebuild     - rebuild image + model, then run"
	@echo "make shell       - bash inside the image"
	@echo "make clean       - remove simulation outputs"
	@echo "make distclean   - also remove the model cache (baochip-1x/verilate/build)"

build:
	./container-run --build-only

sim:
	./container-run sim

build-model:
	./container-run build

rebuild:
	./container-run --rebuild sim

shell:
	./container-run bash

clean:
	rm -rf out

distclean: clean
	rm -rf baochip-1x/verilate/build
