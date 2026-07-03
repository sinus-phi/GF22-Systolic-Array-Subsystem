`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Dummy output readback.
//
// Real output storage should replace this block. For now it produces
// a deterministic pattern so APB output-window reads can be verified.
//-----------------------------------------------------------------------------

module sa_dummy_output (
    input  logic [5:0]  out_word_idx_i,
    input  logic [31:0] config_i,
    output logic [31:0] out_rdata_o
);

  import sa_dummy_pkg::*;

  assign out_rdata_o = output_pattern(out_word_idx_i, config_i);

endmodule
