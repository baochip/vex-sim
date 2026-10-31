// Open-source behavioral model of the ARM 22ULP dual-port register file
// macro rdram1kx32 (1024 words x 32 bits, mux 4, write mask on, 1R/1W).
//
// Translation of the proprietary verilog_memcomp model (port list and
// read/write semantics preserved); follows the bioram1kx32.v template.
// Port A is the read port, port B the write port (wenb active low).
// The test/margin inputs stov, emaa, emasa, emab and retention ret1n are
// accepted but functionally ignored (they only gate x-checks and timing
// checks in the gate-level model); back-door loadmem/dumpmem tasks from
// the proprietary model are not provided.

module rdram1kx32 (qa, clka, cena, aa, clkb, cenb, wenb, ab, db, stov,
    emaa, emasa, emab, ret1n);

  output reg [31:0] qa;
  input  clka;
  input  cena;
  input  [9:0] aa;
  input  clkb;
  input  cenb;
  input  [31:0] wenb;
  input  [9:0] ab;
  input  [31:0] db;
  input  stov;
  input  [2:0] emaa;
  input  emasa;
  input  [2:0] emab;
  input  ret1n;

  parameter RAM_DATA_WIDTH = 32;
  parameter RAM_ADDR_WIDTH = 10;
  parameter WORD_SIZE = 1;
  parameter WORD_WIDTH = 32;

  reg [RAM_DATA_WIDTH-1:0] mem[(2**RAM_ADDR_WIDTH)-1:0];

  integer i, j;
`ifdef SIM
  initial begin
      for (i = 0; i < 2**RAM_ADDR_WIDTH; i = i + 2**(RAM_ADDR_WIDTH/2)) begin
          for (j = i; j < i + 2**(RAM_ADDR_WIDTH/2); j = j + 1) begin
              mem[j] = 'X;
          end
      end
  end
`endif

// read port A
always @(posedge clka) begin
    if (!cena) begin
        qa <= mem[aa];
    end else begin
        qa <= qa;
    end
end

// write port B (per-bit write mask, active low)
always @(posedge clkb) begin
    if (!cenb) begin
        for (i = 0; i < WORD_WIDTH; i = i + 1) begin: writes
            if (!wenb[i]) begin
                mem[ab][WORD_SIZE*i +: WORD_SIZE] <= db[WORD_SIZE*i +: WORD_SIZE];
            end
        end
    end
end

endmodule
