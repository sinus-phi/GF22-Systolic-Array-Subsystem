`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Minimal APB slave adapter for the SA dummy control plane.
//
// The rest of the dummy RTL does not need to know APB timing. It only sees
// one-cycle internal read/write pulses during the APB access phase.
//-----------------------------------------------------------------------------

module sa_apb_if (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    output logic [11:0] local_addr_o,
    output logic [31:0] bus_wdata_o,
    output logic        bus_wena_o,
    output logic        bus_rena_o,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_ready_i,
    input  logic        bus_err_i
);

  logic apb_access;

  // APB access phase: both PSEL and PENABLE are high.
  assign apb_access   = PSEL & PENABLE;

  // Decode is local to the Student_SS_3 4 KiB window.
  assign local_addr_o = PADDR[11:0];
  assign bus_wdata_o  = PWDATA;
  assign bus_wena_o   = apb_access & PWRITE;
  assign bus_rena_o   = apb_access & ~PWRITE;

  // Current dummy fast path has no wait-state source; bus_ready_i is kept so
  // later frontend/output backpressure can be connected without changing APB.
  assign PRDATA  = bus_rdata_i;
  assign PREADY  = apb_access ? bus_ready_i : 1'b0;
  assign PSLVERR = apb_access & bus_ready_i & bus_err_i;

endmodule
