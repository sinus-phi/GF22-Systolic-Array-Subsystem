`timescale 1ns/1ps

module group2_topmodule (
    input  logic [15:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        wrapper_fault_i,

    input  logic        irq_en_i,
    input  logic [15:0] pmod_gpi,
    output logic        irq_o,
    output logic [15:0] pmod_gpo,
    output logic [15:0] pmod_gpio_oe
);

  import group2_pkg::*;

  logic [15:0] local_addr;
  logic [31:0] bus_wdata;
  logic        bus_wena;
  logic        bus_rena;
  logic [31:0] bus_rdata;
  logic        bus_ready;
  logic        bus_err;

  logic        reg_wena;
  logic        reg_rena;
  logic        weight_wena;
  logic        act_wena;
  logic        bias_wena;
  logic        bias_rena;
  logic [3:0]  bias_word_idx;
  logic        out_rena;
  logic [8:0]  out_word_idx;
  logic        dec_err;
  logic [31:0] dec_error_code;

  logic [31:0] config_word;
  logic        config_is_valid;
  logic [511:0] bias_data;
  logic        bias_ready;
  logic        start_gemm_cmd;
  logic        start_gacc_cmd;
  logic        clear_done_cmd;
  logic        clear_error_cmd;
  logic        soft_reset_cmd;
  logic        release_context_cmd;
  logic [31:0] reg_rdata;

  logic        frontend_clear;
  logic        sa_clear;
  logic        buffer_clear;
  logic        operation_gacc;
  logic [4:0]  weight_vector_idx;
  logic [4:0]  act_row_idx;
  logic [8:0]  weight_words_left;
  logic [8:0]  act_words_left;
  logic        busy;
  logic        error_sticky;
  logic        done_sticky;
  logic        context_valid;
  logic        context_match;
  logic        output_readable;
  logic [2:0]  phase;
  logic [31:0] progress;
  logic [31:0] error_code;
  logic [9:0]  output_words;

  logic [1:0]  frontend_precision;
  logic        frontend_word_valid;
  logic        frontend_word_ready;
  logic        frontend_vector_valid;
  logic        frontend_vector_ready;
  logic [127:0] frontend_vector_data;
  logic        weight_word_accept;
  logic        act_word_accept;
  logic        weight_vector_accept;
  logic        act_vector_accept;

  logic        sa_act_ready;
  logic        sa_out_valid;
  logic        sa_out_ready;
  logic        sa_out_bank;
  logic [4:0]  sa_out_row;
  logic [255:0] sa_out_data;
  logic        sa_idle;

  logic        output_beat_commit;
  logic [31:0] output_read_data;
  logic        output_read_ready;
  logic        bus_fault;

  group2_apb_if i_apb_if (
    .PADDR        (PADDR),
    .PENABLE      (PENABLE),
    .PSEL         (PSEL),
    .PWDATA       (PWDATA),
    .PWRITE       (PWRITE),
    .PRDATA       (PRDATA),
    .PREADY       (PREADY),
    .PSLVERR      (PSLVERR),
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .local_addr_o (local_addr),
    .bus_wdata_o  (bus_wdata),
    .bus_wena_o   (bus_wena),
    .bus_rena_o   (bus_rena),
    .bus_rdata_i  (bus_rdata),
    .bus_ready_i  (bus_ready),
    .bus_err_i    (bus_err)
  );

  group2_addr_decoder i_addr_decoder (
    .local_addr_i        (local_addr),
    .bus_wdata_i         (bus_wdata),
    .bus_wena_i          (bus_wena),
    .bus_rena_i          (bus_rena),
    .phase_i             (phase),
    .busy_i              (busy),
    .config_i            (config_word),
    .config_valid_i      (config_is_valid),
    .bias_ready_i        (bias_ready),
    .context_valid_i     (context_valid),
    .context_match_i     (context_match),
    .output_readable_i   (output_readable),
    .output_words_i      (output_words),
    .weight_words_left_i (weight_words_left),
    .act_words_left_i    (act_words_left),
    .reg_wena_o          (reg_wena),
    .reg_rena_o          (reg_rena),
    .weight_wena_o       (weight_wena),
    .act_wena_o          (act_wena),
    .bias_wena_o         (bias_wena),
    .bias_rena_o         (bias_rena),
    .bias_word_idx_o     (bias_word_idx),
    .out_rena_o          (out_rena),
    .out_word_idx_o      (out_word_idx),
    .dec_err_o           (dec_err),
    .dec_error_code_o    (dec_error_code)
  );

  group2_regbank i_regbank (
    .clk_i                 (clk_i),
    .rst_ni                (rst_ni),
    .local_addr_i          (local_addr),
    .bus_wdata_i           (bus_wdata),
    .reg_wena_i            (reg_wena),
    .reg_rena_i            (reg_rena),
    .bias_wena_i           (bias_wena),
    .bias_rena_i           (bias_rena),
    .bias_word_idx_i       (bias_word_idx),
    .busy_i                (busy),
    .error_sticky_i        (error_sticky),
    .done_sticky_i         (done_sticky),
    .context_valid_i       (context_valid),
    .output_readable_i     (output_readable),
    .phase_i               (phase),
    .progress_i            (progress),
    .error_code_i          (error_code),
    .output_words_i        (output_words),
    .irq_en_i              (irq_en_i),
    .pmod_gpi              (pmod_gpi),
    .config_o              (config_word),
    .config_valid_o        (config_is_valid),
    .bias_data_o           (bias_data),
    .bias_ready_o          (bias_ready),
    .start_gemm_cmd_o      (start_gemm_cmd),
    .start_gacc_cmd_o      (start_gacc_cmd),
    .clear_done_cmd_o      (clear_done_cmd),
    .clear_error_cmd_o     (clear_error_cmd),
    .soft_reset_cmd_o      (soft_reset_cmd),
    .release_context_cmd_o (release_context_cmd),
    .reg_rdata_o           (reg_rdata),
    .irq_o                 (irq_o),
    .pmod_gpo              (pmod_gpo),
    .pmod_gpio_oe          (pmod_gpio_oe)
  );

  assign bus_fault = (bus_wena || bus_rena) && dec_err && bus_ready;

  group2_sa_ctrl i_sa_ctrl (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .start_gemm_cmd_i       (start_gemm_cmd),
    .start_gacc_cmd_i       (start_gacc_cmd),
    .clear_done_cmd_i       (clear_done_cmd),
    .clear_error_cmd_i      (clear_error_cmd),
    .soft_reset_cmd_i       (soft_reset_cmd),
    .release_context_cmd_i  (release_context_cmd),
    .bus_fault_i            (bus_fault),
    .bus_fault_code_i       (dec_error_code),
    .wrapper_fault_i        (wrapper_fault_i),
    .config_i               (config_word),
    .weight_word_accept_i   (weight_word_accept),
    .act_word_accept_i      (act_word_accept),
    .weight_vector_accept_i (weight_vector_accept),
    .act_vector_accept_i    (act_vector_accept),
    .output_beat_commit_i   (output_beat_commit),
    .frontend_clear_o       (frontend_clear),
    .sa_clear_o             (sa_clear),
    .buffer_clear_o         (buffer_clear),
    .operation_gacc_o       (operation_gacc),
    .weight_vector_idx_o    (weight_vector_idx),
    .act_row_idx_o          (act_row_idx),
    .weight_words_left_o    (weight_words_left),
    .act_words_left_o       (act_words_left),
    .busy_o                 (busy),
    .error_sticky_o         (error_sticky),
    .done_sticky_o          (done_sticky),
    .context_valid_o        (context_valid),
    .context_match_o        (context_match),
    .output_readable_o      (output_readable),
    .phase_o                (phase),
    .progress_o             (progress),
    .error_code_o           (error_code),
    .output_words_o         (output_words)
  );

  assign frontend_precision    = (phase == PH_WEIGHT) ? config_word[3:2] : config_word[1:0];
  assign frontend_word_valid   = weight_wena || act_wena;
  assign weight_word_accept    = weight_wena && frontend_word_ready;
  assign act_word_accept       = act_wena && frontend_word_ready;
  assign frontend_vector_ready = (phase == PH_WEIGHT) ? 1'b1 : sa_act_ready;
  assign weight_vector_accept  = frontend_vector_valid && frontend_vector_ready &&
                                 (phase == PH_WEIGHT);
  assign act_vector_accept     = frontend_vector_valid && frontend_vector_ready &&
                                 (phase == PH_ACTIVATION);

  group2_input_frontend i_input_frontend (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .clear_i        (frontend_clear),
    .precision_i    (frontend_precision),
    .word_valid_i   (frontend_word_valid),
    .word_ready_o   (frontend_word_ready),
    .word_i         (bus_wdata),
    .vector_valid_o (frontend_vector_valid),
    .vector_ready_i (frontend_vector_ready),
    .vector_data_o  (frontend_vector_data)
  );

  group2_sa i_sa (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .clear_i        (sa_clear),
    .weight_valid_i (weight_vector_accept),
    .weight_col_i   (weight_vector_idx),
    .weight_data_i  (frontend_vector_data),
    .act_valid_i    (act_vector_accept),
    .act_ready_o    (sa_act_ready),
    .act_row_i      (act_row_idx),
    .act_data_i     (frontend_vector_data),
    .out_valid_o    (sa_out_valid),
    .out_ready_i    (sa_out_ready),
    .out_bank_o     (sa_out_bank),
    .out_row_o      (sa_out_row),
    .out_data_o     (sa_out_data),
    .idle_o         (sa_idle)
  );

  group2_output_buffer i_output_buffer (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .clear_i           (buffer_clear),
    .gacc_i            (operation_gacc),
    .beat_valid_i      (sa_out_valid),
    .beat_ready_o      (sa_out_ready),
    .beat_bank_i       (sa_out_bank),
    .beat_row_i        (sa_out_row),
    .beat_data_i       (sa_out_data),
    .beat_commit_o     (output_beat_commit),
    .bias_enable_i     (cfg_bias_enable(config_word)),
    .bias_data_i       (bias_data),
    .rd_req_i          (out_rena),
    .rd_word_idx_i     (out_word_idx),
    .rd_data_o         (output_read_data),
    .rd_ready_o        (output_read_ready)
  );

  always_comb begin
    bus_ready = 1'b1;
    bus_rdata = reg_rdata;
    bus_err   = dec_err;

    if (!dec_err && (weight_wena || act_wena)) begin
      bus_ready = frontend_word_ready;
    end else if (!dec_err && out_rena) begin
      bus_ready = output_read_ready;
      bus_rdata = output_read_data;
    end
  end

  wire _unused = &{1'b0, sa_idle, 1'b0};

endmodule
