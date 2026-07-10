`timescale 1ns/1ps

// GF22 ASIC implementation of the Group 2 single-port 32x128 SRAM contract.
// Read data is valid in the cycle indicated by rvalid_o. SRAM contents are not
// reset; reset only suppresses accesses and clears the read-valid metadata.
module group2_sram_32x128 (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         en_i,
    input  logic         we_i,
    input  logic [4:0]   addr_i,
    input  logic [127:0] wdata_i,
    output logic [127:0] rdata_o,
    output logic         rvalid_o
);

  logic         macro_en;
  logic [127:0] macro_rdata;

  // The macro uses active-low chip enable and 0=write/1=read RDWEN.
  assign macro_en = en_i && rst_ni;

  MBH_ZSNL_mem_32x128 i_mem_32x128 (
    .clk       (clk_i),
    .cen       (!macro_en),
    .rdwen     (!we_i),
    .deepsleep (1'b0),
    .powergate (1'b0),
    .a         (addr_i),
    .d         (wdata_i),
    .bw        ({128{1'b1}}),
    .q         (macro_rdata)
  );

  assign rdata_o = macro_rdata;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
    end else begin
      rvalid_o <= en_i && !we_i;
    end
  end

endmodule
