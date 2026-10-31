// Open-source behavioral model of the ARM 22ULP dual-port register file
// macro rdram512x64 (512 words x 64 bits, mux 4, 1R/1W).
//
// Translation of the proprietary verilog_memcomp model (port list and
// read/write semantics preserved); follows the bioram1kx32.v template.
// Port A is the read port, port B the write port (no bit write mask).
// The test/margin inputs stov, emaa, emasa, emab and retention ret1n are
// accepted but functionally ignored (they only gate x-checks and timing
// checks in the gate-level model); back-door loadmem/dumpmem tasks from
// the proprietary model are not provided.

module rdram512x64 (qa, clka, cena, aa, clkb, cenb, ab, db, stov,
    emaa, emasa, emab, ret1n);

  output reg [63:0] qa;
  input  clka;
  input  cena;
  input  [8:0] aa;
  input  clkb;
  input  cenb;
  input  [8:0] ab;
  input  [63:0] db;
  input  stov;
  input  [2:0] emaa;
  input  emasa;
  input  [2:0] emab;
  input  ret1n;

  parameter RAM_DATA_WIDTH = 64;
  parameter RAM_ADDR_WIDTH = 9;
  parameter WORD_SIZE = 1;
  parameter WORD_WIDTH = 64;

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

// write port B (full word)
always @(posedge clkb) begin
    if (!cenb) begin
        mem[ab] <= db;
    end
end

endmodule
