`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// SRAM/BRAM-friendly output buffer for the subsystem.
//
// group2_sa_ctrl writes one full row per beat. APB reads expose a
// compact M x N stream of 64-bit accumulator results as 32-bit words. The
// storage is not physically cleared; clear_i only invalidates the registered
// read response. This matches memory macros where bulk clear is usually not
// available.
//
// Physical layout is row-wide: one memory entry stores all ARRAY_WIDTH lanes of
// one output row.  The write path decodes the controller's byte-address-like
// row stride parametrically instead of assuming a fixed 8x8, 64-byte layout.
// The read path maps a compact firmware word index back to row/lane/word
// selection.
//-----------------------------------------------------------------------------

module group2_output_buffer #(
    parameter int ACC_WIDTH = 64,
    parameter int ARRAY_HEIGHT = 8,
    parameter int ARRAY_WIDTH = 8,
    parameter int BUFF_ADDR_WIDTH = 10
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         clear_i,

    input  logic                         wr_en_i,
    input  logic [BUFF_ADDR_WIDTH-1:0]   wr_addr_i,
    input  logic [ARRAY_WIDTH*ACC_WIDTH-1:0] wr_data_i,

    input  logic                         rd_req_i,
    input  logic [31:0]                  tile_n_i,
    input  logic [7:0]                   rd_word_idx_i,
    output logic [31:0]                  rd_data_o,
    output logic                         rd_valid_o
);

  localparam int WORDS_PER_ACC = ACC_WIDTH / 32;
  localparam int ROW_DATA_WIDTH = ARRAY_WIDTH * ACC_WIDTH;
  localparam int ROW_BYTES = ROW_DATA_WIDTH / 8;
  localparam int ROW_INDEX_WIDTH = (ARRAY_HEIGHT <= 1) ? 1 : $clog2(ARRAY_HEIGHT);
  localparam int LANE_INDEX_WIDTH = (ARRAY_WIDTH <= 1) ? 1 : $clog2(ARRAY_WIDTH);
  localparam int ACC_WORD_INDEX_WIDTH = (WORDS_PER_ACC <= 1) ? 1 : $clog2(WORDS_PER_ACC);
  localparam int COMPACT_DECODE_WIDTH =
      ROW_INDEX_WIDTH + LANE_INDEX_WIDTH + ACC_WORD_INDEX_WIDTH;
  localparam logic [BUFF_ADDR_WIDTH-1:0] ROW_ADDR_STRIDE = ROW_BYTES;

  // Keep the physical output rows in a reset-less synchronous memory.  Vivado
  // can map this style to BRAM, while an async reset on the memory array tends
  // to force thousands of flip-flops instead.
  (* ram_style = "block" *) logic [ROW_DATA_WIDTH-1:0] row_mem_q [0:ARRAY_HEIGHT-1];
  logic [ROW_DATA_WIDTH-1:0] row_rd_data_q;

  logic [ROW_INDEX_WIDTH-1:0]      wr_row_idx;
  logic [ROW_INDEX_WIDTH-1:0]      rd_row_idx;
  logic [LANE_INDEX_WIDTH-1:0]     rd_lane_idx;
  logic [ACC_WORD_INDEX_WIDTH-1:0] rd_acc_word_idx;
  logic [LANE_INDEX_WIDTH-1:0]     rd_lane_idx_q;
  logic [ACC_WORD_INDEX_WIDTH-1:0] rd_acc_word_idx_q;
  logic                            rd_pipe_q;

  function automatic logic [ROW_INDEX_WIDTH-1:0] decode_write_row_index(
      input logic [BUFF_ADDR_WIDTH-1:0] wr_addr
  );
    logic [BUFF_ADDR_WIDTH-1:0] row_base;
    integer row_scan;
    begin
      decode_write_row_index = '0;
      row_base = '0;

      // group2_sa_ctrl presents byte-address-like row offsets:
      //   row 0 -> 0 * ROW_BYTES
      //   row 1 -> 1 * ROW_BYTES
      //   ...
      // Scan fixed row bases instead of slicing wr_addr_i[8:6], so this stays
      // correct if ARRAY_WIDTH or ACC_WIDTH changes.
      for (row_scan = 0; row_scan < ARRAY_HEIGHT; row_scan = row_scan + 1) begin
        if (wr_addr >= row_base) begin
          decode_write_row_index = row_scan[ROW_INDEX_WIDTH-1:0];
        end
        row_base = row_base + ROW_ADDR_STRIDE;
      end
    end
  endfunction

  function automatic logic [COMPACT_DECODE_WIDTH-1:0] decode_compact_index(
      input logic [7:0] rd_idx,
      input logic [3:0] tile_n
  );
    logic [7:0] words_per_row;
    logic [7:0] row_base;
    logic [7:0] word_in_row;
    logic [7:0] lane_base;
    logic [7:0] lane_word_offset;
    logic [ROW_INDEX_WIDTH-1:0] row_idx;
    logic [LANE_INDEX_WIDTH-1:0] lane_idx;
    logic [ACC_WORD_INDEX_WIDTH-1:0] acc_word_idx;
    integer row_scan;
    integer lane_scan;
    begin
      words_per_row = {4'd0, tile_n} * WORDS_PER_ACC;
      row_base      = 8'd0;
      word_in_row   = 8'd0;
      lane_base     = 8'd0;
      lane_word_offset = 8'd0;
      row_idx       = '0;
      lane_idx      = '0;
      acc_word_idx  = '0;

      // Avoid run-time division/modulo in the read path. The compact stream is
      // decoded by small fixed compare/subtract chains, which are more
      // predictable for synthesis than a variable divider.
      if (words_per_row != 8'd0) begin
        for (row_scan = 0; row_scan < ARRAY_HEIGHT; row_scan = row_scan + 1) begin
          if (rd_idx >= row_base) begin
            row_idx     = row_scan[ROW_INDEX_WIDTH-1:0];
            word_in_row = rd_idx - row_base;
          end
          row_base = row_base + words_per_row;
        end
      end

      for (lane_scan = 0; lane_scan < ARRAY_WIDTH; lane_scan = lane_scan + 1) begin
        if (word_in_row >= lane_base) begin
          lane_word_offset = word_in_row - lane_base;
          lane_idx         = lane_scan[LANE_INDEX_WIDTH-1:0];
          acc_word_idx     = lane_word_offset[ACC_WORD_INDEX_WIDTH-1:0];
        end
        lane_base = lane_base + WORDS_PER_ACC;
      end

      decode_compact_index = {
        row_idx,
        lane_idx,
        acc_word_idx
      };
    end
  endfunction

  assign wr_row_idx = decode_write_row_index(wr_addr_i);
  assign {rd_row_idx, rd_lane_idx, rd_acc_word_idx} =
      decode_compact_index(rd_word_idx_i, tile_n_i[3:0]);

  always_ff @(posedge clk_i) begin
    if (wr_en_i) begin
      // Whole-row write: all physical output lanes are captured together.
      row_mem_q[wr_row_idx] <= wr_data_i;
    end

    if (rd_req_i) begin
      // Synchronous row read.  The 32-bit word selection happens one cycle
      // later from row_rd_data_q, matching FPGA BRAM read semantics.
      row_rd_data_q <= row_mem_q[rd_row_idx];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_data_o      <= 32'd0;
      rd_valid_o     <= 1'b0;
      rd_lane_idx_q  <= '0;
      rd_acc_word_idx_q <= '0;
      rd_pipe_q      <= 1'b0;
    end else begin
      if (clear_i) begin
        rd_data_o         <= 32'd0;
        rd_valid_o        <= 1'b0;
        rd_lane_idx_q     <= '0;
        rd_acc_word_idx_q <= '0;
        rd_pipe_q         <= 1'b0;
      end else begin
        rd_valid_o <= rd_pipe_q;

        if (rd_pipe_q) begin
          rd_data_o <= row_rd_data_q[
              (rd_lane_idx_q * ACC_WIDTH) + (rd_acc_word_idx_q * 32) +: 32];
        end

        rd_pipe_q <= rd_req_i;
        if (rd_req_i) begin
          rd_lane_idx_q     <= rd_lane_idx;
          rd_acc_word_idx_q <= rd_acc_word_idx;
        end
      end
    end
  end

endmodule
