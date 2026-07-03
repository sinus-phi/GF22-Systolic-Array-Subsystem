`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Shared constants and small helper functions for the SA student subsystem.
//
// This package keeps the firmware-visible map, phase encoding, and compact
// CONFIG decoding consistent across decoder, RegBank, FSM, and testbench.
// Any field visible to firmware should be defined here first, then consumed by
// the RTL blocks.  This reduces accidental disagreement between modules.
//-----------------------------------------------------------------------------

package group2_pkg;

  // Hardware tile shape.  The current SA datapath is fixed at 8x8, so larger
  // GEMM problems must be tiled by firmware.
  //
  // The output buffer stores one 8x8 tile of 64-bit accumulator results,
  // exposed as 32-bit APB words.
  localparam logic [31:0] ARRAY_HEIGHT       = 32'd8;
  localparam logic [31:0] ARRAY_WIDTH        = 32'd8;
  localparam logic [31:0] ACC_WORDS_PER_ELEM = 32'd2;
  localparam logic [31:0] MAX_OUTPUT_WORDS   = 32'd128;
  localparam int          SA_ARRAY_HEIGHT    = 8;
  localparam int          SA_ARRAY_WIDTH     = 8;
  localparam int          SA_MAC_STAGES      = 2;

  // Compact control-plane register map. Debug-only registers are intentionally
  // left out of this v1 skeleton; firmware should treat unlisted addresses as
  // illegal.
  localparam logic [15:0] OFF_CONTROL      = 16'h0000;
  localparam logic [15:0] OFF_STATUS       = 16'h0004;
  localparam logic [15:0] OFF_CONFIG       = 16'h0008;
  localparam logic [15:0] OFF_PROGRESS     = 16'h000C;
  localparam logic [15:0] OFF_ERROR_CODE   = 16'h0010;
  localparam logic [15:0] OFF_OUTPUT_WORDS = 16'h0014;

  localparam logic [31:0] ERR_NONE           = 32'd0;
  localparam logic [31:0] ERR_BAD_ADDR       = 32'd1;
  localparam logic [31:0] ERR_UNALIGNED      = 32'd2;
  localparam logic [31:0] ERR_BAD_STATE      = 32'd3;
  localparam logic [31:0] ERR_OUTPUT_RANGE   = 32'd4;
  localparam logic [31:0] ERR_INVALID_CONFIG = 32'd5;
  localparam logic [31:0] ERR_FATAL_CTRL     = 32'd6;

  // Error hierarchy:
  //   ERR_BAD_* / ERR_UNALIGNED / ERR_INVALID_CONFIG are recoverable APB
  //   access faults.  The decoder suppresses the rejected target pulse, so the
  //   active transaction can continue after firmware clears sticky status.
  //   ERR_FATAL_CTRL is reserved for internal controller invariant failures.
  //   Arithmetic overflow is reported by STATUS.overflow_sticky, not by
  //   ERROR_CODE, because the PE saturates and the GEMM can still complete.
  //
  // Compact v1 FSM encoding. There is no top-level DONE state; completion is
  // represented by done_sticky plus output_valid. Only fatal controller faults
  // enter PH_ERROR; ordinary APB ordering mistakes do not abort the transaction.
  localparam logic [2:0] PH_IDLE            = 3'd0;
  localparam logic [2:0] PH_LOAD_WEIGHTS    = 3'd1;
  localparam logic [2:0] PH_BATCH_COMPUTE   = 3'd2;
  localparam logic [2:0] PH_DRAIN_WRITEBACK = 3'd3;
  localparam logic [2:0] PH_ERROR           = 3'd4;

  function automatic logic [31:0] elems_per_word(input logic [1:0] precision);
    case (precision)
      2'b00: elems_per_word = 32'd8; // INT4
      2'b01: elems_per_word = 32'd4; // INT8
      2'b10: elems_per_word = 32'd2; // INT16
      default: elems_per_word = 32'd1; // INT32
    endcase
  endfunction

  function automatic logic [31:0] ceil_div(
      input logic [31:0] numerator,
      input logic [31:0] denominator
  );
    if (denominator == 32'd0) begin
      ceil_div = 32'd0;
    end else begin
      ceil_div = (numerator + denominator - 32'd1) / denominator;
    end
  endfunction

  function automatic logic [31:0] cfg_tile_m(input logic [31:0] cfg);
    cfg_tile_m = {27'd0, cfg[8:4]};
  endfunction

  function automatic logic [31:0] cfg_tile_n(input logic [31:0] cfg);
    cfg_tile_n = {27'd0, cfg[13:9]};
  endfunction

  function automatic logic [31:0] cfg_tile_k(input logic [31:0] cfg);
    cfg_tile_k = {27'd0, cfg[18:14]};
  endfunction

  function automatic logic [31:0] cfg_batch_count(input logic [31:0] cfg);
    cfg_batch_count = {26'd0, cfg[24:19]};
  endfunction

  // The SA physical vector is ARRAY_HEIGHT lanes wide, but a tile may use fewer
  // K lanes.  The frontend pads lanes tile_k..7 with zero when tile_k < 8.
  //
  // Firmware contract:
  //   - Stream ceil(tile_k / elems_per_word(precision)) words per vector.
  //   - Do not pack the next vector into unused high elements of the last word;
  //     those high elements are ignored by the frontend for the current vector.
  function automatic logic [31:0] packed_words_per_vector(input logic [1:0] precision);
    packed_words_per_vector = ceil_div(ARRAY_HEIGHT, elems_per_word(precision));
  endfunction

  function automatic logic [31:0] packed_words_for_k(
      input logic [1:0]  precision,
      input logic [31:0] tile_k
  );
    packed_words_for_k = ceil_div(tile_k, elems_per_word(precision));
  endfunction

  // Number of APB words that complete the weight phase.  One full vector is
  // loaded per output column.
  function automatic logic [31:0] weight_words_for(input logic [31:0] cfg);
    weight_words_for = cfg_tile_n(cfg) * packed_words_for_k(cfg[3:2], cfg_tile_k(cfg));
  endfunction

  // Number of APB words that complete one activation batch.  One full vector is
  // sent per input row.
  function automatic logic [31:0] act_words_for(input logic [31:0] cfg);
    act_words_for = cfg_tile_m(cfg) * packed_words_for_k(cfg[1:0], cfg_tile_k(cfg));
  endfunction

  // Firmware reads each 64-bit accumulator as two 32-bit words.  The stream is
  // compacted to tile_m x tile_n rather than exposing all physical 8x8 lanes.
  function automatic logic [31:0] output_words_for(input logic [31:0] cfg);
    logic [31:0] words;
    words = cfg_tile_m(cfg) * cfg_tile_n(cfg) * ACC_WORDS_PER_ELEM;
    if (words > MAX_OUTPUT_WORDS) begin
      output_words_for = MAX_OUTPUT_WORDS;
    end else begin
      output_words_for = words;
    end
  endfunction

  function automatic logic [31:0] raw_output_words_for(input logic [31:0] cfg);
    raw_output_words_for = cfg_tile_m(cfg) * cfg_tile_n(cfg) * ACC_WORDS_PER_ELEM;
  endfunction

  // Keep config restrictions narrow for the first integration point: 1..8 tile
  // dimensions and one 8x8 64-bit output tile maximum.
  function automatic logic config_valid(input logic [31:0] cfg);
    logic [31:0] tile_m;
    logic [31:0] tile_n;
    logic [31:0] tile_k;
    logic [31:0] batch_count;
    begin
      tile_m      = cfg_tile_m(cfg);
      tile_n      = cfg_tile_n(cfg);
      tile_k      = cfg_tile_k(cfg);
      batch_count = cfg_batch_count(cfg);
      config_valid =
          (cfg[31:25] == 7'd0) &&
          (tile_m > 32'd0) && (tile_m <= 32'd8) &&
          (tile_n > 32'd0) && (tile_n <= 32'd8) &&
          (tile_k > 32'd0) && (tile_k <= 32'd8) &&
          (batch_count > 32'd0) && (batch_count <= 32'd32) &&
          (raw_output_words_for(cfg) <= MAX_OUTPUT_WORDS);
    end
  endfunction

endpackage
