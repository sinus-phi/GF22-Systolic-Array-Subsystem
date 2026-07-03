`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Single-authority SA control FSM.
//
// This block owns the externally visible 5-state subsystem flow.  Input
// vectorization is delegated to group2_input_frontend. Output drain/write
// timing is kept here as a small counter-based scheduler so there is no second
// system-control FSM.
//
// Error handling is hierarchical:
//   - Recoverable APB access faults only set sticky ERROR_CODE. The decoder
//     suppresses the rejected local pulse, so the running transaction is not
//     aborted.
//   - Arithmetic overflow sets overflow_sticky. The PE saturates the affected
//     accumulator and the GEMM continues.
//   - Fatal controller faults are reserved for violated internal invariants.
//     Those faults enter PH_ERROR and drop the current weight/output context.
//
// Firmware contract:
//   1. Write CONFIG in IDLE.
//   2. Pulse CONTROL.load_weights.
//   3. Stream the expected number of weight words.
//   4. Stream the expected number of activation words for each batch.
//   5. Wait for output_valid, copy the compact output window into firmware
//      scratch storage, then pulse release_output as soon as the copy is done.
//      Longer accumulation/checking should happen after release so the next
//      activation batch is not blocked by the single output buffer.
//-----------------------------------------------------------------------------

module group2_sa_ctrl #(
    parameter int ACC_WIDTH = 64,
    parameter int ARRAY_HEIGHT = 8,
    parameter int ARRAY_WIDTH = 8,
    parameter int MAC_STAGES = 2,
    parameter int BUFF_ADDR_WIDTH = 10
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        load_weights_cmd_i,
    input  logic        release_output_cmd_i,
    input  logic        clear_done_cmd_i,
    input  logic        clear_error_cmd_i,
    input  logic        soft_reset_cmd_i,

    input  logic        dec_err_i,
    input  logic [31:0] dec_error_code_i,
    input  logic        weight_wena_i,
    input  logic        act_wena_i,
    input  logic        input_vector_valid_i,
    input  logic        mac_overflow_i,

    input  logic [31:0] config_i,
    input  logic        config_valid_i,

    output logic        weight_start_o,
    output logic        activation_start_o,
    output logic        load_settle_active_o,
    output logic        output_drain_active_o,
    output logic        out_wr_en_o,
    output logic [BUFF_ADDR_WIDTH-1:0] out_wr_addr_o,

    output logic [2:0]  phase_o,
    output logic        weights_valid_o,
    output logic        done_sticky_o,
    output logic        error_sticky_o,
    output logic        overflow_sticky_o,
    output logic        output_valid_o,
    output logic        output_full_o,
    output logic        output_blocked_o,
    output logic [31:0] output_words_o,
    output logic [31:0] error_code_o
);

  import group2_pkg::*;

  // The SA load signal is skewed across columns.  After the final weight vector
  // is accepted, the controller keeps advancing the array so the load wave can
  // settle and the last column captures its weight before activations begin.
  // This does not clear PE weight registers; it is a timing-settle interval for
  // the in-flight load/data wavefront.
  localparam int LOAD_SETTLE_CYCLES = ((ARRAY_WIDTH - 1) * MAC_STAGES) + 1;
  localparam int LOAD_SETTLE_COUNT_WIDTH = $clog2(LOAD_SETTLE_CYCLES + 1);
  localparam logic [LOAD_SETTLE_COUNT_WIDTH-1:0] LOAD_SETTLE_LIMIT =
      LOAD_SETTLE_CYCLES;

  // Output writeback starts only after the activation wavefront has propagated
  // through the full array.  The counter below replaces a separate output FSM.
  localparam int OUTPUT_START_CYCLES = (ARRAY_HEIGHT + ARRAY_WIDTH - 1) * MAC_STAGES;
  localparam int OUT_CNTR_WIDTH = $clog2(OUTPUT_START_CYCLES + ARRAY_HEIGHT + 2);
  localparam logic [OUT_CNTR_WIDTH-1:0] OUTPUT_START_LIMIT = OUTPUT_START_CYCLES;
  localparam logic [BUFF_ADDR_WIDTH-1:0] OUTPUT_ADDR_STRIDE =
      (ACC_WIDTH * ARRAY_WIDTH) / 8;
  localparam int STREAM_COUNT_WIDTH = $clog2((ARRAY_WIDTH * ARRAY_HEIGHT) + 1);
  localparam int ROW_COUNT_WIDTH = $clog2(ARRAY_HEIGHT + 1);
  localparam int BATCH_COUNT_WIDTH = $clog2(32 + 1);

  logic [2:0]  phase_q;
  logic        weights_valid_q;
  logic        done_sticky_q;
  logic        error_sticky_q;
  logic        overflow_sticky_q;
  logic        output_valid_q;
  logic        output_blocked_q;
  logic [31:0] error_code_q;
  // These counters are intentionally sized to the actual compact-v1 limits
  // instead of 32 bits.  The largest stream is 8 vectors x 8 INT32 words = 64
  // APB words.  batch_count is limited by CONFIG validation to 1..32.
  logic [STREAM_COUNT_WIDTH-1:0] weight_count_q;
  logic [STREAM_COUNT_WIDTH-1:0] act_count_q;
  logic [BATCH_COUNT_WIDTH-1:0]  batch_remaining_q;
  logic        weight_stream_done_q;
  logic [LOAD_SETTLE_COUNT_WIDTH-1:0] load_settle_count_q;
  logic        output_active_q;
  logic [OUT_CNTR_WIDTH-1:0] output_advance_count_q;
  logic [ROW_COUNT_WIDTH-1:0] output_rows_written_q;
  logic [31:0] tile_m_value;
  logic [ROW_COUNT_WIDTH-1:0] tile_m_rows;
  logic [31:0] weight_target_full;
  logic [31:0] act_target_full;
  logic [31:0] batch_count_full;
  logic [STREAM_COUNT_WIDTH-1:0] weight_target;
  logic [STREAM_COUNT_WIDTH-1:0] act_target;
  logic [BATCH_COUNT_WIDTH-1:0] batch_count_start;
  logic [31:0] output_words_value;

  logic        weight_start_q;
  logic        activation_start_q;

  wire load_settle_active = (phase_q == PH_LOAD_WEIGHTS) &&
                            weight_stream_done_q &&
                            (load_settle_count_q < LOAD_SETTLE_LIMIT);
  wire output_drain_active = output_active_q &&
                             (phase_q == PH_DRAIN_WRITEBACK) &&
                             (output_rows_written_q < tile_m_rows);
  wire output_sa_advance = output_active_q &&
                           (input_vector_valid_i || output_drain_active);
  wire output_write_now = output_sa_advance &&
                          (output_advance_count_q >= OUTPUT_START_LIMIT) &&
                          (output_rows_written_q < tile_m_rows);
  wire output_done_now = output_write_now &&
                         ((output_rows_written_q + 1'b1) >= tile_m_rows);
  wire active_transaction = (phase_q == PH_LOAD_WEIGHTS) ||
                            (phase_q == PH_BATCH_COMPUTE) ||
                            (phase_q == PH_DRAIN_WRITEBACK);
  wire fatal_ctrl_fault =
      (active_transaction && !config_valid_i) ||
      ((phase_q == PH_LOAD_WEIGHTS) && (weight_target_full == 32'd0)) ||
      ((phase_q == PH_BATCH_COMPUTE) && (act_target_full == 32'd0)) ||
      ((phase_q == PH_DRAIN_WRITEBACK) && (tile_m_rows == '0));

  assign tile_m_value = cfg_tile_m(config_i);
  assign tile_m_rows  = tile_m_value[ROW_COUNT_WIDTH-1:0];
  assign weight_target_full = weight_words_for(config_i);
  assign act_target_full = act_words_for(config_i);
  assign batch_count_full = cfg_batch_count(config_i);
  assign weight_target = weight_target_full[STREAM_COUNT_WIDTH-1:0];
  assign act_target = act_target_full[STREAM_COUNT_WIDTH-1:0];
  assign batch_count_start = batch_count_full[BATCH_COUNT_WIDTH-1:0];
  assign output_words_value = output_words_for(config_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q              <= PH_IDLE;
      weights_valid_q      <= 1'b0;
      done_sticky_q        <= 1'b0;
      error_sticky_q       <= 1'b0;
      overflow_sticky_q    <= 1'b0;
      output_valid_q       <= 1'b0;
      output_blocked_q     <= 1'b0;
      error_code_q         <= ERR_NONE;
      weight_count_q       <= '0;
      act_count_q          <= '0;
      batch_remaining_q    <= '0;
      weight_stream_done_q <= 1'b0;
      load_settle_count_q  <= '0;
      output_active_q      <= 1'b0;
      output_advance_count_q <= '0;
      output_rows_written_q  <= '0;
      weight_start_q       <= 1'b0;
      activation_start_q   <= 1'b0;
    end else begin
      weight_start_q     <= 1'b0;
      activation_start_q <= 1'b0;
      output_blocked_q   <= 1'b0;

      if (soft_reset_cmd_i) begin
        phase_q              <= PH_IDLE;
        weights_valid_q      <= 1'b0;
        done_sticky_q        <= 1'b0;
        error_sticky_q       <= 1'b0;
        overflow_sticky_q    <= 1'b0;
        output_valid_q       <= 1'b0;
        error_code_q         <= ERR_NONE;
        weight_count_q       <= '0;
        act_count_q          <= '0;
        batch_remaining_q    <= '0;
        weight_stream_done_q <= 1'b0;
        load_settle_count_q  <= '0;
        output_active_q      <= 1'b0;
        output_advance_count_q <= '0;
        output_rows_written_q  <= '0;
      end

      else begin
        if (dec_err_i) begin
          // Address-decoder faults are APB-visible access faults, not automatic
          // transaction aborts.  The decoder suppresses all target pulses on a
          // rejected access, so the datapath state is not corrupted.  Keep the
          // current phase running and report the first outstanding fault through
          // sticky status until firmware clears it.
          error_sticky_q <= 1'b1;
          if (!error_sticky_q || clear_error_cmd_i) begin
            error_code_q <= dec_error_code_i;
          end
        end

        if (clear_done_cmd_i) begin
          done_sticky_q <= 1'b0;
        end

        if (clear_error_cmd_i) begin
          error_sticky_q <= 1'b0;
          overflow_sticky_q <= 1'b0;
          error_code_q   <= ERR_NONE;
          if (phase_q == PH_ERROR) begin
            phase_q <= PH_IDLE;
          end
        end

        if (mac_overflow_i) begin
          // Saturation does not stop the GEMM.  The PE clamps the affected
          // partial sum and this sticky flag lets firmware detect that at
          // least one output was saturated.
          overflow_sticky_q <= 1'b1;
        end

        if (fatal_ctrl_fault) begin
          // This is intentionally narrow: normal firmware mistakes are already
          // rejected by the decoder and are recoverable.  PH_ERROR is used only
          // when the controller's own assumptions are violated, for example an
          // active transaction with an invalid/zero-sized configuration.
          phase_q              <= PH_ERROR;
          weights_valid_q      <= 1'b0;
          done_sticky_q        <= 1'b0;
          output_valid_q       <= 1'b0;
          output_active_q      <= 1'b0;
          error_sticky_q       <= 1'b1;
          error_code_q         <= ERR_FATAL_CTRL;
          weight_count_q       <= '0;
          act_count_q          <= '0;
          batch_remaining_q    <= '0;
          weight_stream_done_q <= 1'b0;
          load_settle_count_q  <= '0;
          output_advance_count_q <= '0;
          output_rows_written_q  <= '0;
        end else begin
          // Output scheduling is intentionally counter-only. The global phase
          // stays in this FSM; no separate output FSM owns control flow.
          if (output_sa_advance) begin
            output_advance_count_q <= output_advance_count_q + 1'b1;

            if (output_write_now) begin
              output_rows_written_q <= output_rows_written_q + 1'b1;
              if (output_done_now) begin
                output_active_q <= 1'b0;
              end
            end
          end

          unique case (phase_q)
            PH_IDLE: begin
              // Release in IDLE is allowed as a harmless cleanup command.  It also
              // drops the weight context, which keeps CONFIG updates simple for
              // the compact v1 firmware model.
              if (release_output_cmd_i) begin
                output_valid_q <= 1'b0;
                weights_valid_q <= 1'b0;
              end

              if (load_weights_cmd_i) begin
                phase_q              <= PH_LOAD_WEIGHTS;
                weights_valid_q      <= 1'b0;
                done_sticky_q        <= 1'b0;
                error_sticky_q       <= 1'b0;
                overflow_sticky_q    <= 1'b0;
                error_code_q         <= ERR_NONE;
                output_valid_q       <= 1'b0;
                batch_remaining_q    <= batch_count_start;
                weight_count_q       <= '0;
                act_count_q          <= '0;
                weight_stream_done_q <= 1'b0;
                load_settle_count_q  <= '0;
                output_active_q      <= 1'b0;
                output_advance_count_q <= '0;
                output_rows_written_q  <= '0;
                weight_start_q       <= 1'b1;
              end
            end

            PH_LOAD_WEIGHTS: begin
              // Count APB weight words, not vectors.  The target already accounts
              // for precision packing and number of output columns.
              if (weight_wena_i && !weight_stream_done_q) begin
                weight_count_q <= weight_count_q + 1'b1;
                if ((weight_count_q + 1'b1) >= weight_target) begin
                  weight_stream_done_q <= 1'b1;
                  load_settle_count_q  <= '0;
                end
              end else if (load_settle_active) begin
                load_settle_count_q <= load_settle_count_q + 1'b1;
              end

              if (weight_stream_done_q && (load_settle_count_q >= LOAD_SETTLE_LIMIT)) begin
                phase_q              <= PH_BATCH_COMPUTE;
                weights_valid_q      <= 1'b1;
                act_count_q          <= '0;
                activation_start_q   <= 1'b1;
                weight_stream_done_q <= 1'b0;
                output_active_q      <= 1'b1;
                output_advance_count_q <= '0;
                output_rows_written_q  <= '0;
              end
            end

            PH_BATCH_COMPUTE: begin
              // Each activation batch is one tile_m x tile_k input tile.  After
              // the last word arrives, switch to drain/writeback so the remaining
              // partial sums can be pushed into the output buffer.
              if (act_wena_i) begin
                act_count_q <= act_count_q + 1'b1;
                if ((act_count_q + 1'b1) >= act_target) begin
                  phase_q <= PH_DRAIN_WRITEBACK;
                end
              end
            end

            PH_DRAIN_WRITEBACK: begin
              // output_valid means firmware owns the output buffer contents.  For
              // multi-batch mode the FSM waits here until firmware releases the
              // current output, then accepts the next activation batch using the
              // same loaded weights.
              if (!output_valid_q && output_done_now) begin
                output_valid_q    <= 1'b1;
                done_sticky_q     <= 1'b1;
                batch_remaining_q <= batch_remaining_q - 1'b1;
              end else if (output_valid_q && (batch_remaining_q > '0)) begin
                if (release_output_cmd_i) begin
                  output_valid_q     <= 1'b0;
                  phase_q            <= PH_BATCH_COMPUTE;
                  act_count_q        <= '0;
                  activation_start_q <= 1'b1;
                  output_active_q    <= 1'b1;
                  output_advance_count_q <= '0;
                  output_rows_written_q  <= '0;
                end else begin
                  output_blocked_q <= 1'b1;
                end
              end else if (output_valid_q && (batch_remaining_q == '0)) begin
                if (release_output_cmd_i) begin
                  output_valid_q <= 1'b0;
                  weights_valid_q <= 1'b0;
                end
                phase_q <= PH_IDLE;
              end
            end

            PH_ERROR: begin
              // Hold a fatal state until firmware explicitly clears the sticky
              // fault or performs soft reset.  Recoverable APB faults never
              // enter this phase.
            end

            default: begin
              phase_q        <= PH_ERROR;
              error_sticky_q <= 1'b1;
              error_code_q   <= ERR_FATAL_CTRL;
            end
          endcase
        end
      end
    end
  end

  assign weight_start_o       = weight_start_q;
  assign activation_start_o   = activation_start_q;
  assign load_settle_active_o = load_settle_active && !fatal_ctrl_fault;
  assign output_drain_active_o = output_drain_active && !fatal_ctrl_fault;
  assign out_wr_en_o          = output_write_now && !fatal_ctrl_fault;
  assign out_wr_addr_o        = output_rows_written_q * OUTPUT_ADDR_STRIDE;

  assign phase_o              = phase_q;
  assign weights_valid_o      = weights_valid_q;
  assign done_sticky_o        = done_sticky_q;
  assign error_sticky_o       = error_sticky_q;
  assign overflow_sticky_o    = overflow_sticky_q;
  assign output_valid_o       = output_valid_q;
  assign output_full_o        = output_valid_q;
  assign output_blocked_o     = output_blocked_q;
  assign output_words_o       = output_words_value;
  assign error_code_o         = error_code_q;

endmodule
