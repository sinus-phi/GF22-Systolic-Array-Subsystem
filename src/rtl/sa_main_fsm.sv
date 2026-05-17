`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Main control FSM for the SA dummy skeleton.
//
// This is a control-plane model, not a GEMM datapath. It counts accepted APB
// words to emulate weight load, activation batch compute, and result drain.
// Completion is exposed through done_sticky/output_valid instead of a DONE
// state, matching the compact 5-state contract.
//-----------------------------------------------------------------------------

module sa_main_fsm (
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

    input  logic [31:0] config_i,

    output logic [2:0]  phase_o,
    output logic        weights_valid_o,
    output logic        done_sticky_o,
    output logic        error_sticky_o,
    output logic        output_valid_o,
    output logic        output_full_o,
    output logic        output_blocked_o,
    output logic [1:0]  output_valid_count_o,
    output logic [31:0] output_words_o,
    output logic [31:0] error_code_o,
    output logic [31:0] progress_current_o,
    output logic [31:0] progress_target_o,
    output logic [31:0] batch_remaining_o,
    output logic [1:0]  progress_kind_o,
    output logic        done_event_o,
    output logic        error_event_o
);

  import sa_dummy_pkg::*;

  logic [2:0]  phase_q;
  logic        weights_valid_q;
  logic        done_sticky_q;
  logic        error_sticky_q;
  logic        output_valid_q;
  logic        output_blocked_q;
  logic [31:0] output_words_q;
  logic [31:0] error_code_q;
  logic [31:0] weight_count_q;
  logic [31:0] act_count_q;
  logic [31:0] drain_count_q;
  logic [31:0] drain_batch_count_q;
  logic [31:0] weight_target_q;
  logic [31:0] act_target_q;
  logic [31:0] batch_remaining_q;
  logic        done_event_q;
  logic        error_event_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q             <= PH_IDLE;
      weights_valid_q     <= 1'b0;
      done_sticky_q       <= 1'b0;
      error_sticky_q      <= 1'b0;
      output_valid_q      <= 1'b0;
      output_blocked_q    <= 1'b0;
      output_words_q      <= 32'd0;
      error_code_q        <= ERR_NONE;
      weight_count_q      <= 32'd0;
      act_count_q         <= 32'd0;
      drain_count_q       <= 32'd0;
      drain_batch_count_q <= 32'd0;
      weight_target_q     <= 32'd0;
      act_target_q        <= 32'd0;
      batch_remaining_q   <= 32'd0;
      done_event_q        <= 1'b0;
      error_event_q       <= 1'b0;
    end else begin
      // Event outputs are pulses; sticky status is tracked separately.
      done_event_q  <= 1'b0;
      error_event_q <= 1'b0;

      if (soft_reset_cmd_i) begin
        // Local reset drops the current weight/output context and returns to
        // the idle configuration point.
        phase_q             <= PH_IDLE;
        weights_valid_q     <= 1'b0;
        done_sticky_q       <= 1'b0;
        error_sticky_q      <= 1'b0;
        output_valid_q      <= 1'b0;
        output_blocked_q    <= 1'b0;
        output_words_q      <= 32'd0;
        error_code_q        <= ERR_NONE;
        weight_count_q      <= 32'd0;
        act_count_q         <= 32'd0;
        drain_count_q       <= 32'd0;
        drain_batch_count_q <= 32'd0;
        weight_target_q     <= 32'd0;
        act_target_q        <= 32'd0;
        batch_remaining_q   <= 32'd0;
      end

      else if (dec_err_i) begin
        // Decoder errors have priority over normal progress so the bad APB
        // access is captured immediately.
        phase_q          <= PH_ERROR;
        error_sticky_q   <= 1'b1;
        error_code_q     <= dec_error_code_i;
        output_blocked_q <= 1'b0;
        error_event_q    <= 1'b1;
      end

      else begin
        // These commands are orthogonal to the current phase. release_output
        // frees the single dummy output slot but does not clear done_sticky.
        if (release_output_cmd_i) begin
          output_valid_q <= 1'b0;
        end

        if (clear_done_cmd_i) begin
          done_sticky_q <= 1'b0;
        end

        if (clear_error_cmd_i) begin
          error_sticky_q <= 1'b0;
          error_code_q   <= ERR_NONE;
          if (phase_q == PH_ERROR) begin
            phase_q <= PH_IDLE;
          end
        end

        output_blocked_q <= 1'b0;

        if (load_weights_cmd_i) begin
          // Start of one weight transaction. Expected word counts are latched
          // from CONFIG so later CONFIG writes cannot affect an active run.
          phase_q             <= PH_LOAD_WEIGHTS;
          weights_valid_q     <= 1'b0;
          error_sticky_q      <= 1'b0;
          error_code_q        <= ERR_NONE;
          weight_count_q      <= 32'd0;
          act_count_q         <= 32'd0;
          drain_count_q       <= 32'd0;
          drain_batch_count_q <= 32'd0;
          weight_target_q     <= weight_words_for(config_i);
          act_target_q        <= act_words_for(config_i);
          output_words_q      <= output_words_for(config_i);
          batch_remaining_q   <= cfg_batch_count(config_i);
        end

        else if (weight_wena_i && (phase_q == PH_LOAD_WEIGHTS)) begin
          // Count accepted weight words. The real frontend/scheduler will
          // eventually replace this with accepted token progress.
          weight_count_q <= weight_count_q + 32'd1;
          if ((weight_count_q + 32'd1) >= weight_target_q) begin
            phase_q         <= PH_BATCH_COMPUTE;
            weights_valid_q <= 1'b1;
            act_count_q     <= 32'd0;
          end
        end

        else if (act_wena_i && (phase_q == PH_BATCH_COMPUTE)) begin
          // One activation batch is complete once the expected word count has
          // been accepted for the current weight context.
          act_count_q <= act_count_q + 32'd1;
          if ((act_count_q + 32'd1) >= act_target_q) begin
            phase_q             <= PH_DRAIN_WRITEBACK;
            drain_batch_count_q <= 32'd0;
          end
        end

        else if (phase_q == PH_DRAIN_WRITEBACK) begin
          // Dummy single-slot output model. If firmware has not released the
          // previous result set, hold DRAIN_WRITEBACK and expose output_blocked.
          if (output_valid_q && !release_output_cmd_i) begin
            output_blocked_q <= 1'b1;
          end else if (drain_batch_count_q < output_words_q) begin
            // Real hardware will wait for SA/result stream completion here.
            // The dummy drains one output word per cycle.
            drain_batch_count_q <= drain_batch_count_q + 32'd1;
            drain_count_q       <= drain_count_q + 32'd1;

            if ((drain_batch_count_q + 32'd1) >= output_words_q) begin
              // A readable result set now exists. This is the replacement for
              // the removed top-level DONE state.
              output_valid_q    <= 1'b1;
              done_sticky_q     <= 1'b1;
              done_event_q      <= 1'b1;
              batch_remaining_q <= batch_remaining_q - 32'd1;

              if ((batch_remaining_q - 32'd1) > 32'd0) begin
                phase_q     <= PH_BATCH_COMPUTE;
                act_count_q <= 32'd0;
              end else begin
                phase_q <= PH_IDLE;
              end
            end
          end
        end
      end
    end
  end

  always_comb begin
    // Select a compact progress snapshot for firmware polling.
    progress_current_o = 32'd0;
    progress_target_o  = 32'd0;
    progress_kind_o    = PROG_NONE;

    unique case (phase_q)
      PH_LOAD_WEIGHTS: begin
        progress_current_o = weight_count_q;
        progress_target_o  = weight_target_q;
        progress_kind_o    = PROG_WEIGHT;
      end

      PH_BATCH_COMPUTE: begin
        progress_current_o = act_count_q;
        progress_target_o  = act_target_q;
        progress_kind_o    = PROG_ACTIVATION;
      end

      PH_DRAIN_WRITEBACK: begin
        progress_current_o = drain_batch_count_q;
        progress_target_o  = output_words_q;
        progress_kind_o    = PROG_DRAIN;
      end

      default: begin
        progress_current_o = 32'd0;
        progress_target_o  = 32'd0;
        progress_kind_o    = PROG_NONE;
      end
    endcase
  end

  assign phase_o              = phase_q;
  assign weights_valid_o      = weights_valid_q;
  assign done_sticky_o        = done_sticky_q;
  assign error_sticky_o       = error_sticky_q;
  assign output_valid_o       = output_valid_q;
  assign output_full_o        = output_valid_q;
  assign output_blocked_o     = output_blocked_q;
  assign output_valid_count_o = output_valid_q ? 2'd1 : 2'd0;
  assign output_words_o       = output_words_q;
  assign error_code_o         = error_code_q;
  assign batch_remaining_o    = batch_remaining_q;
  assign done_event_o         = done_event_q;
  assign error_event_o        = error_event_q;

endmodule
