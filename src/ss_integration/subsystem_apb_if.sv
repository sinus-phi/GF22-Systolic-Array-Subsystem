`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// APB slave adapter for the SA subsystem control plane.
//
// The rest of the RTL does not need to know APB timing. It only sees
// one-cycle internal read/write pulses. The adapter keeps the APB transfer
// open until the selected backend reports that the response is ready, which
// lets SRAM/BRAM-backed reads add wait states without changing the register
// or datapath blocks.
//-----------------------------------------------------------------------------

module subsystem_apb_if (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        clk_i,
    input  logic        rst_ni,

    output logic [11:0] local_addr_o,
    output logic [31:0] bus_wdata_o,
    output logic        bus_wena_o,
    output logic        bus_rena_o,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_ready_i,
    input  logic        bus_err_i
);

  logic apb_access;
  logic apb_access_q;
  logic request_start;
  logic pending_q;
  logic [11:0] local_addr_q;
  logic [31:0] bus_wdata_q;
  logic        bus_wena_q;
  logic        bus_rena_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      apb_access_q <= 1'b0;
      pending_q    <= 1'b0;
      local_addr_q <= 12'd0;
      bus_wdata_q  <= 32'd0;
      bus_wena_q   <= 1'b0;
      bus_rena_q   <= 1'b0;
    end else begin
      apb_access_q <= apb_access;
      bus_wena_q   <= 1'b0;
      bus_rena_q   <= 1'b0;

      if (request_start) begin
        // Latch address/control at the start of the APB access phase.  The
        // selected backend may hold PREADY low, so these values must remain
        // stable until bus_ready_i completes the transfer.
        local_addr_q <= PADDR[11:0];
        bus_wdata_q  <= PWDATA;
        bus_wena_q   <= PWRITE;
        bus_rena_q   <= ~PWRITE;
        pending_q    <= 1'b1;
      end else if (pending_q && bus_ready_i) begin
        pending_q    <= 1'b0;
      end
    end
  end

  // APB access phase: both PSEL and PENABLE are high.
  assign apb_access    = PSEL & PENABLE;
  assign request_start = apb_access & ~apb_access_q & ~pending_q;

  // Decode is local to the selected Student_SS 4 KiB window.  The SoC interconnect
  // already selected this subsystem, so only PADDR[11:0] is relevant here.
  assign local_addr_o = local_addr_q;
  assign bus_wdata_o  = bus_wdata_q;
  assign bus_wena_o   = bus_wena_q;
  assign bus_rena_o   = bus_rena_q;

  // PREADY is asserted only when the accepted local request has a valid
  // response. Fast register accesses can return in the next APB wait cycle;
  // memory-backed reads can hold bus_ready_i low for additional cycles.
  assign PRDATA  = bus_rdata_i;
  assign PREADY  = pending_q & bus_ready_i;
  assign PSLVERR = pending_q & bus_ready_i & bus_err_i;

endmodule
