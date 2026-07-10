`timescale 1ns/1ps

// Synchronous single-port 32x128 SRAM model used by FPGA and simulation.
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

  (* ram_style = "distributed" *) logic [127:0] mem_q [0:31];

  // Memory contents are not reset; only the registered read interface is.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rdata_o  <= '0;
      rvalid_o <= 1'b0;
    end else begin
      rvalid_o <= en_i && !we_i;
      if (en_i) begin
        if (we_i) begin
          mem_q[addr_i] <= wdata_i;
        end else begin
          rdata_o <= mem_q[addr_i];
        end
      end
    end
  end

endmodule
