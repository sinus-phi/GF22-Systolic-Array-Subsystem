`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Shared constants and small helper functions for the SA dummy skeleton.
//
// This package keeps the firmware-visible map, phase encoding, and compact
// CONFIG decoding consistent across decoder, RegBank, FSM, and testbench.
//-----------------------------------------------------------------------------

package sa_dummy_pkg;

  // Dummy output window is capped to one 8x8 result tile.
  localparam logic [31:0] MAX_OUTPUT_WORDS = 32'd64;

  // Compact control-plane register map. Debug-only registers from the first
  // dummy model are intentionally left out of this v1 skeleton.
  localparam logic [11:0] OFF_CONTROL      = 12'h000;
  localparam logic [11:0] OFF_STATUS       = 12'h004;
  localparam logic [11:0] OFF_CONFIG       = 12'h008;
  localparam logic [11:0] OFF_PROGRESS     = 12'h00C;
  localparam logic [11:0] OFF_ERROR_CODE   = 12'h010;
  localparam logic [11:0] OFF_OUTPUT_WORDS = 12'h014;

  localparam logic [31:0] ERR_NONE           = 32'd0;
  localparam logic [31:0] ERR_BAD_ADDR       = 32'd1;
  localparam logic [31:0] ERR_UNALIGNED      = 32'd2;
  localparam logic [31:0] ERR_BAD_STATE      = 32'd3;
  localparam logic [31:0] ERR_OUTPUT_RANGE   = 32'd4;
  localparam logic [31:0] ERR_INVALID_CONFIG = 32'd5;

  // Compact v1 FSM encoding. There is no top-level DONE state; completion is
  // represented by done_sticky plus output_valid.
  localparam logic [2:0] PH_IDLE            = 3'd0;
  localparam logic [2:0] PH_LOAD_WEIGHTS    = 3'd1;
  localparam logic [2:0] PH_BATCH_COMPUTE   = 3'd2;
  localparam logic [2:0] PH_DRAIN_WRITEBACK = 3'd3;
  localparam logic [2:0] PH_ERROR           = 3'd4;

  // PROGRESS identifies which internal counter is currently visible.
  localparam logic [1:0] PROG_NONE       = 2'd0;
  localparam logic [1:0] PROG_WEIGHT     = 2'd1;
  localparam logic [1:0] PROG_ACTIVATION = 2'd2;
  localparam logic [1:0] PROG_DRAIN      = 2'd3;

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

  // Expected APB word counts for the current tile. The dummy model only counts
  // accepted words; real unpacking and PE scheduling will be added later.
  function automatic logic [31:0] weight_words_for(input logic [31:0] cfg);
    weight_words_for = ceil_div(
        cfg_tile_k(cfg) * cfg_tile_n(cfg),
        elems_per_word(cfg[3:2])
    );
  endfunction

  function automatic logic [31:0] act_words_for(input logic [31:0] cfg);
    act_words_for = ceil_div(
        cfg_tile_m(cfg) * cfg_tile_k(cfg),
        elems_per_word(cfg[1:0])
    );
  endfunction

  function automatic logic [31:0] output_words_for(input logic [31:0] cfg);
    logic [31:0] words;
    words = cfg_tile_m(cfg) * cfg_tile_n(cfg);
    if (words > MAX_OUTPUT_WORDS) begin
      output_words_for = MAX_OUTPUT_WORDS;
    end else begin
      output_words_for = words;
    end
  endfunction

  // Keep config restrictions narrow for the first integration point: full-word
  // APB inputs, 1..8 tile dimensions, and one 8x8 output tile maximum.
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
          ((tile_m * tile_n) <= MAX_OUTPUT_WORDS);
    end
  endfunction

  // Deterministic placeholder data for output-window testing.
  function automatic logic [31:0] output_pattern(
      input logic [5:0]  idx,
      input logic [31:0] cfg_word
  );
    output_pattern = 32'hA500_0000 | ({24'd0, idx} << 8) | {24'd0, cfg_word[7:0]};
  endfunction

endpackage
