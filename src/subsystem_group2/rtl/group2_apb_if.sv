`timescale 1ns/1ps

// Holds one APB access until the internal target completes it.
module group2_apb_if (
    input  logic [15:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        clk_i,
    input  logic        rst_ni,

    output logic [15:0] local_addr_o,
    output logic [31:0] bus_wdata_o,
    output logic        bus_wena_o,
    output logic        bus_rena_o,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_ready_i,
    input  logic        bus_err_i
);

  logic        pending_q;
  logic [15:0] addr_q;
  logic [31:0] wdata_q;
  logic        write_q;

  // Capture APB only in its access phase; keep fields stable during stalls.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
      addr_q    <= '0;
      wdata_q   <= '0;
      write_q   <= 1'b0;
    end else begin
      if (!pending_q && PSEL && PENABLE) begin
        pending_q <= 1'b1;
        addr_q    <= PADDR;
        wdata_q   <= PWDATA;
        write_q   <= PWRITE;
      end else if (pending_q && bus_ready_i) begin
        pending_q <= 1'b0;
      end
    end
  end

  assign local_addr_o = addr_q;
  assign bus_wdata_o  = wdata_q;
  assign bus_wena_o   = pending_q && write_q;
  assign bus_rena_o   = pending_q && !write_q;

  // APB completes only when the selected internal target is ready.
  assign PRDATA  = bus_rdata_i;
  assign PREADY  = pending_q && bus_ready_i;
  assign PSLVERR = pending_q && bus_ready_i && bus_err_i;

endmodule
