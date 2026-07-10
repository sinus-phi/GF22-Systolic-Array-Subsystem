`timescale 1ns/1ps

module group2_sa_ctrl (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        start_gemm_cmd_i,
    input  logic        start_gacc_cmd_i,
    input  logic        clear_done_cmd_i,
    input  logic        clear_error_cmd_i,
    input  logic        soft_reset_cmd_i,
    input  logic        release_context_cmd_i,

    input  logic        bus_fault_i,
    input  logic [31:0] bus_fault_code_i,
    input  logic        wrapper_fault_i,
    input  logic [31:0] config_i,

    input  logic        weight_word_accept_i,
    input  logic        act_word_accept_i,
    input  logic        weight_vector_accept_i,
    input  logic        act_vector_accept_i,
    input  logic        output_beat_commit_i,

    output logic        frontend_clear_o,
    output logic        sa_clear_o,
    output logic        buffer_clear_o,
    output logic        operation_gacc_o,
    output logic [4:0]  weight_vector_idx_o,
    output logic [4:0]  act_row_idx_o,
    output logic [8:0]  weight_words_left_o,
    output logic [8:0]  act_words_left_o,

    output logic        busy_o,
    output logic        error_sticky_o,
    output logic        done_sticky_o,
    output logic        context_valid_o,
    output logic        context_match_o,
    output logic        output_readable_o,
    output logic [2:0]  phase_o,
    output logic [31:0] progress_o,
    output logic [31:0] error_code_o,
    output logic [9:0]  output_words_o
);

  import group2_pkg::*;

  logic [2:0]  phase_q;
  logic        operation_gacc_q;
  logic        error_sticky_q;
  logic        done_sticky_q;
  logic        context_valid_q;
  logic [31:0] context_config_q;
  logic [31:0] error_code_q;
  logic [8:0]  weight_words_left_q;
  logic [8:0]  act_words_left_q;
  logic [5:0]  weight_vector_count_q;
  logic [5:0]  act_vector_count_q;
  logic [6:0]  output_beat_count_q;
  logic [6:0]  expected_output_beats;

  assign phase_o             = phase_q;
  assign operation_gacc_o    = operation_gacc_q;
  assign error_sticky_o      = error_sticky_q;
  assign done_sticky_o       = done_sticky_q;
  assign context_valid_o     = context_valid_q;
  assign context_match_o     = context_valid_q && (context_config_q[10:0] == config_i[10:0]);
  assign output_readable_o   = context_valid_q && (phase_q == PH_OUTPUT);
  assign weight_words_left_o = weight_words_left_q;
  assign act_words_left_o    = act_words_left_q;
  assign weight_vector_idx_o = weight_vector_count_q[4:0];
  assign act_row_idx_o       = act_vector_count_q[4:0];
  assign error_code_o        = error_code_q;
  assign output_words_o      = output_words_for(context_valid_q ? context_config_q : config_i);
  assign expected_output_beats = {1'b0, cfg_rows_m(config_i)} << 1;
  assign busy_o = (phase_q == PH_WEIGHT) || (phase_q == PH_ACTIVATION) ||
                  (phase_q == PH_DRAIN) || (phase_q == PH_GACC);

  always_comb begin
    progress_o = 32'd0;
    progress_o[8:0]   = weight_words_for(config_i) - weight_words_left_q;
    progress_o[17:9]  = activation_words_for(config_i) - act_words_left_q;
    progress_o[24:18] = output_beat_count_q;
    progress_o[27:25] = phase_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      phase_q               <= PH_IDLE;
      operation_gacc_q      <= 1'b0;
      error_sticky_q        <= 1'b0;
      done_sticky_q         <= 1'b0;
      context_valid_q       <= 1'b0;
      context_config_q      <= '0;
      error_code_q          <= ERR_NONE;
      weight_words_left_q   <= '0;
      act_words_left_q      <= '0;
      weight_vector_count_q <= '0;
      act_vector_count_q    <= '0;
      output_beat_count_q   <= '0;
      frontend_clear_o      <= 1'b0;
      sa_clear_o            <= 1'b0;
      buffer_clear_o        <= 1'b0;
    end else begin
      frontend_clear_o <= 1'b0;
      sa_clear_o       <= 1'b0;
      buffer_clear_o   <= 1'b0;

      if ((bus_fault_i || wrapper_fault_i) && !error_sticky_q) begin
        error_sticky_q <= 1'b1;
        error_code_q   <= wrapper_fault_i ? ERR_PARTIAL_WRITE : bus_fault_code_i;
      end
      if (clear_error_cmd_i) begin
        error_sticky_q <= 1'b0;
        error_code_q   <= ERR_NONE;
      end
      if (clear_done_cmd_i) begin
        done_sticky_q <= 1'b0;
      end

      if (soft_reset_cmd_i) begin
        phase_q               <= PH_IDLE;
        operation_gacc_q      <= 1'b0;
        error_sticky_q        <= 1'b0;
        done_sticky_q         <= 1'b0;
        context_valid_q       <= 1'b0;
        context_config_q      <= '0;
        error_code_q          <= ERR_NONE;
        weight_words_left_q   <= '0;
        act_words_left_q      <= '0;
        weight_vector_count_q <= '0;
        act_vector_count_q    <= '0;
        output_beat_count_q   <= '0;
        frontend_clear_o      <= 1'b1;
        sa_clear_o            <= 1'b1;
        buffer_clear_o        <= 1'b1;
      end else if (release_context_cmd_i) begin
        phase_q             <= PH_IDLE;
        context_valid_q     <= 1'b0;
        done_sticky_q       <= 1'b0;
        output_beat_count_q <= '0;
        buffer_clear_o      <= 1'b1;
      end else if (start_gemm_cmd_i || start_gacc_cmd_i) begin
        phase_q               <= PH_WEIGHT;
        operation_gacc_q      <= start_gacc_cmd_i;
        done_sticky_q         <= 1'b0;
        context_valid_q       <= start_gacc_cmd_i;
        context_config_q      <= start_gacc_cmd_i ? context_config_q : config_i;
        weight_words_left_q   <= weight_words_for(config_i);
        act_words_left_q      <= activation_words_for(config_i);
        weight_vector_count_q <= '0;
        act_vector_count_q    <= '0;
        output_beat_count_q   <= '0;
        frontend_clear_o      <= 1'b1;
        sa_clear_o            <= 1'b1;
        buffer_clear_o        <= 1'b1;
      end else begin
        if (weight_word_accept_i && (weight_words_left_q != 0)) begin
          weight_words_left_q <= weight_words_left_q - 1'b1;
        end
        if (act_word_accept_i && (act_words_left_q != 0)) begin
          act_words_left_q <= act_words_left_q - 1'b1;
        end

        if (weight_vector_accept_i) begin
          weight_vector_count_q <= weight_vector_count_q + 1'b1;
          if ((weight_vector_count_q == 6'd31) && (weight_words_left_q == 0)) begin
            phase_q <= PH_ACTIVATION;
          end
        end

        if (act_vector_accept_i) begin
          act_vector_count_q <= act_vector_count_q + 1'b1;
          if ((act_vector_count_q + 1'b1) == {1'b0, cfg_rows_m(config_i)} &&
              (act_words_left_q == 0)) begin
            phase_q <= operation_gacc_q ? PH_GACC : PH_DRAIN;
          end
        end

        if (output_beat_commit_i) begin
          output_beat_count_q <= output_beat_count_q + 1'b1;
          if ((output_beat_count_q + 1'b1) == expected_output_beats) begin
            phase_q           <= PH_OUTPUT;
            done_sticky_q     <= 1'b1;
            context_valid_q   <= 1'b1;
            context_config_q  <= config_i;
          end
        end
      end
    end
  end

endmodule
