`timescale 1ns/1ps

// Shared register map, dimensions, and arithmetic helpers.
package group2_pkg;

  // Compute-array and output-buffer geometry.
  localparam int DATA_WIDTH         = 16;
  localparam int SA_ARRAY_HEIGHT    = 8;
  localparam int SA_ARRAY_WIDTH     = 16;
  localparam int LOGICAL_COLUMNS    = 32;
  localparam int OUTPUT_DEPTH       = 32;
  localparam int OUTPUT_WORDS_ROW   = 16;
  localparam int MAX_OUTPUT_WORDS   = OUTPUT_DEPTH * OUTPUT_WORDS_ROW;

  // Local APB offsets.
  localparam logic [15:0] OFF_CONTROL      = 16'h0000;
  localparam logic [15:0] OFF_STATUS       = 16'h0004;
  localparam logic [15:0] OFF_CONFIG       = 16'h0008;
  localparam logic [15:0] OFF_PROGRESS     = 16'h000C;
  localparam logic [15:0] OFF_ERROR_CODE   = 16'h0010;
  localparam logic [15:0] OFF_OUTPUT_WORDS = 16'h0014;
  localparam logic [15:0] OFF_VERSION      = 16'h0018;
  localparam logic [15:0] OFF_CAPABILITY   = 16'h001C;
  localparam logic [15:0] OFF_WEIGHT_DATA  = 16'h0100;
  localparam logic [15:0] OFF_ACT_DATA     = 16'h0200;
  localparam logic [15:0] OFF_BIAS_BASE    = 16'h0300;
  localparam logic [15:0] OFF_BIAS_LAST    = 16'h033C;
  localparam logic [15:0] OFF_OUTPUT_BASE  = 16'h0400;
  localparam logic [15:0] OFF_OUTPUT_LAST  = 16'h0BFF;

  // CAPABILITY: dtype mask, array size, max M, accumulator, bias/GACC/stream.
  localparam logic [31:0] VERSION = 32'h0001_0000;
  localparam logic [31:0] CAPABILITY =
      (32'h7 << 0)  |
      (32'd8 << 4)  |
      (32'd16 << 8) |
      (32'd32 << 13) |
      (32'd16 << 19) |
      (32'h1 << 24) |
      (32'h1 << 25) |
      (32'h1 << 26);

  // Packed input precision.
  localparam logic [1:0] DTYPE_INT4  = 2'd0;
  localparam logic [1:0] DTYPE_INT8  = 2'd1;
  localparam logic [1:0] DTYPE_INT16 = 2'd2;

  // Software-visible phases.
  localparam logic [2:0] PH_IDLE       = 3'd0;
  localparam logic [2:0] PH_WEIGHT     = 3'd1;
  localparam logic [2:0] PH_ACTIVATION = 3'd2;
  localparam logic [2:0] PH_DRAIN      = 3'd3;
  localparam logic [2:0] PH_GACC       = 3'd4;
  localparam logic [2:0] PH_OUTPUT     = 3'd5;
  localparam logic [2:0] PH_FATAL      = 3'd6;

  // Sticky error codes.
  localparam logic [31:0] ERR_NONE                 = 32'd0;
  localparam logic [31:0] ERR_BAD_ADDR             = 32'd1;
  localparam logic [31:0] ERR_UNALIGNED            = 32'd2;
  localparam logic [31:0] ERR_PARTIAL_WRITE        = 32'd3;
  localparam logic [31:0] ERR_BAD_STATE            = 32'd4;
  localparam logic [31:0] ERR_INVALID_CONFIG       = 32'd5;
  localparam logic [31:0] ERR_UNSUPPORTED_DTYPE    = 32'd6;
  localparam logic [31:0] ERR_STREAM_COUNT         = 32'd7;
  localparam logic [31:0] ERR_OUTPUT_NOT_READY     = 32'd8;
  localparam logic [31:0] ERR_INVALID_GACC_CONTEXT = 32'd9;
  localparam logic [31:0] ERR_BIAS_NOT_READY       = 32'd10;
  localparam logic [31:0] ERR_ILLEGAL_COMMAND      = 32'd11;
  localparam logic [31:0] ERR_FATAL_INTERNAL       = 32'd12;

  // CONTROL commands.
  localparam logic [31:0] CTRL_START_GEMM      = 32'h0000_0001;
  localparam logic [31:0] CTRL_START_GACC      = 32'h0000_0002;
  localparam logic [31:0] CTRL_CLEAR_DONE      = 32'h0000_0004;
  localparam logic [31:0] CTRL_CLEAR_ERROR     = 32'h0000_0008;
  localparam logic [31:0] CTRL_SOFT_RESET      = 32'h0000_0010;
  localparam logic [31:0] CTRL_RELEASE_CONTEXT = 32'h0000_0020;

  // CONFIG: act[1:0], weight[3:2], rows M[9:4], bias enable[10].
  function automatic logic [5:0] cfg_rows_m(input logic [31:0] cfg);
    cfg_rows_m = cfg[9:4];
  endfunction

  function automatic logic cfg_bias_enable(input logic [31:0] cfg);
    cfg_bias_enable = cfg[10];
  endfunction

  function automatic logic dtype_supported(input logic [1:0] dtype);
    dtype_supported = (dtype != 2'b11);
  endfunction

  function automatic logic config_valid(input logic [31:0] cfg);
    logic [5:0] rows;
    begin
      rows = cfg_rows_m(cfg);
      config_valid = (cfg[31:11] == '0) &&
                     dtype_supported(cfg[1:0]) &&
                     dtype_supported(cfg[3:2]) &&
                     (rows >= 6'd1) && (rows <= 6'd32);
    end
  endfunction

  // One vector expands to eight signed INT16 lanes.
  function automatic logic [2:0] words_per_vector(input logic [1:0] dtype);
    case (dtype)
      DTYPE_INT4:  words_per_vector = 3'd1;
      DTYPE_INT8:  words_per_vector = 3'd2;
      DTYPE_INT16: words_per_vector = 3'd4;
      default:     words_per_vector = 3'd0;
    endcase
  endfunction

  // Words required for one operation.
  function automatic logic [8:0] weight_words_for(input logic [31:0] cfg);
    weight_words_for =
        9'(LOGICAL_COLUMNS) * words_per_vector(cfg[3:2]);
  endfunction

  function automatic logic [8:0] activation_words_for(input logic [31:0] cfg);
    activation_words_for =
        9'(cfg_rows_m(cfg)) * words_per_vector(cfg[1:0]);
  endfunction

  // Each output word contains two INT16 results.
  function automatic logic [9:0] output_words_for(input logic [31:0] cfg);
    output_words_for = {4'd0, cfg_rows_m(cfg)} << 4;
  endfunction

  // Accept exactly one defined CONTROL bit.
  function automatic logic onehot_command(input logic [31:0] command);
    logic [31:0] masked;
    begin
      masked = command & 32'h0000_003F;
      onehot_command = (command[31:6] == '0) &&
                       (masked != '0) && ((masked & (masked - 1'b1)) == '0);
    end
  endfunction

  // Architectural modulo-2^16 addition.
  function automatic logic signed [15:0] add_wrap16(
      input logic signed [15:0] lhs,
      input logic signed [15:0] rhs
  );
    logic signed [16:0] sum;
    begin
      sum = lhs + rhs;
      add_wrap16 = sum[15:0];
    end
  endfunction

endpackage
