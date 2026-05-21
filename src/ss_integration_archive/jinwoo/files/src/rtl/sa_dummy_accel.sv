`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// SA dummy accelerator top
//
// This top wires the APB shell, local decoder, compact register bank, 5-state
// control FSM, and deterministic output window.  The real frontend, scheduler,
// SA core, and output storage can be connected at the same ownership points.
//-----------------------------------------------------------------------------

module sa_dummy_accel (
    // APB
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    // Clocks and reset
    input  logic        clk_i,
    input  logic        rst_ni,

    // SoC-level sideband
    input  logic        irq_en_i,
    input  logic [7:0]  ss_ctrl_i,
    input  logic [15:0] pmod_gpi,
    output logic        irq_o,
    output logic [15:0] pmod_gpo,
    output logic [15:0] pmod_gpio_oe
);

  logic [11:0] local_addr;
  logic [31:0] bus_wdata;
  logic        bus_wena;
  logic        bus_rena;
  logic [31:0] bus_rdata;
  logic        bus_err;

  logic        reg_wena;
  logic        reg_rena;
  logic        weight_wena;
  logic        act_wena;
  logic        out_rena;
  logic [5:0]  out_word_idx;
  logic        dec_err;
  logic [31:0] dec_error_code;

  logic [31:0] config_word;
  logic        config_valid;
  logic        load_weights_cmd;
  logic        release_output_cmd;
  logic        soft_reset_cmd;
  logic        clear_done_cmd;
  logic        clear_error_cmd;
  logic [31:0] reg_rdata;

  logic [2:0]  phase;
  logic        weights_valid;
  logic        done_sticky;
  logic        error_sticky;
  logic        output_valid;
  logic        output_full;
  logic        output_blocked;
  logic [1:0]  output_valid_count;
  logic [31:0] output_words;
  logic [31:0] error_code;
  logic [31:0] progress_current;
  logic [31:0] progress_target;
  logic [31:0] batch_remaining;
  logic [1:0]  progress_kind;
  logic        done_event;
  logic        error_event;
  logic [31:0] output_rdata;

  // APB timing adapter. The dummy model keeps bus_ready high, but the internal
  // interface already has ready/error hooks for later backpressure.
  sa_apb_if i_apb_if (
    .PADDR        (PADDR),
    .PENABLE      (PENABLE),
    .PSEL         (PSEL),
    .PWDATA       (PWDATA),
    .PWRITE       (PWRITE),
    .PRDATA       (PRDATA),
    .PREADY       (PREADY),
    .PSLVERR      (PSLVERR),
    .local_addr_o (local_addr),
    .bus_wdata_o  (bus_wdata),
    .bus_wena_o   (bus_wena),
    .bus_rena_o   (bus_rena),
    .bus_rdata_i  (bus_rdata),
    .bus_ready_i  (1'b1),
    .bus_err_i    (bus_err)
  );

  // Decode local addresses into register, weight, activation, or output-window
  // accesses. Illegal accesses are reported to APB and latched by the FSM.
  sa_addr_decoder i_addr_decoder (
    .local_addr_i      (local_addr),
    .bus_wdata_i       (bus_wdata),
    .bus_wena_i        (bus_wena),
    .bus_rena_i        (bus_rena),
    .phase_i           (phase),
    .config_valid_i    (config_valid),
    .weights_valid_i   (weights_valid),
    .output_valid_i    (output_valid),
    .output_words_i    (output_words),
    .reg_wena_o        (reg_wena),
    .reg_rena_o        (reg_rena),
    .weight_wena_o     (weight_wena),
    .act_wena_o        (act_wena),
    .out_rena_o        (out_rena),
    .out_word_idx_o    (out_word_idx),
    .dec_err_o         (dec_err),
    .dec_error_code_o  (dec_error_code)
  );

  // Firmware-visible control/status block. CONTROL writes become command
  // pulses; STATUS/PROGRESS mirror FSM and output state.
  sa_regbank i_regbank (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .local_addr_i         (local_addr),
    .bus_wdata_i          (bus_wdata),
    .reg_wena_i           (reg_wena),
    .reg_rena_i           (reg_rena),
    .phase_i              (phase),
    .weights_valid_i      (weights_valid),
    .done_sticky_i        (done_sticky),
    .error_sticky_i       (error_sticky),
    .output_valid_i       (output_valid),
    .output_full_i        (output_full),
    .output_blocked_i     (output_blocked),
    .output_valid_count_i (output_valid_count),
    .output_words_i       (output_words),
    .error_code_i         (error_code),
    .progress_current_i   (progress_current),
    .progress_target_i    (progress_target),
    .batch_remaining_i    (batch_remaining),
    .progress_kind_i      (progress_kind),
    .irq_en_i             (irq_en_i),
    .pmod_gpi             (pmod_gpi),
    .config_o             (config_word),
    .config_valid_o       (config_valid),
    .load_weights_cmd_o   (load_weights_cmd),
    .release_output_cmd_o (release_output_cmd),
    .clear_done_cmd_o     (clear_done_cmd),
    .clear_error_cmd_o    (clear_error_cmd),
    .soft_reset_cmd_o     (soft_reset_cmd),
    .reg_rdata_o          (reg_rdata),
    .irq_o                (irq_o),
    .pmod_gpo             (pmod_gpo),
    .pmod_gpio_oe         (pmod_gpio_oe)
  );

  // 5-state control model. It consumes accepted input-window writes and
  // produces sticky done/error plus output-valid state.
  sa_main_fsm i_main_fsm (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .load_weights_cmd_i   (load_weights_cmd),
    .release_output_cmd_i (release_output_cmd),
    .clear_done_cmd_i     (clear_done_cmd),
    .clear_error_cmd_i    (clear_error_cmd),
    .soft_reset_cmd_i     (soft_reset_cmd),
    .dec_err_i            (dec_err),
    .dec_error_code_i     (dec_error_code),
    .weight_wena_i        (weight_wena),
    .act_wena_i           (act_wena),
    .config_i             (config_word),
    .phase_o              (phase),
    .weights_valid_o      (weights_valid),
    .done_sticky_o        (done_sticky),
    .error_sticky_o       (error_sticky),
    .output_valid_o       (output_valid),
    .output_full_o        (output_full),
    .output_blocked_o     (output_blocked),
    .output_valid_count_o (output_valid_count),
    .output_words_o       (output_words),
    .error_code_o         (error_code),
    .progress_current_o   (progress_current),
    .progress_target_o    (progress_target),
    .batch_remaining_o    (batch_remaining),
    .progress_kind_o      (progress_kind),
    .done_event_o         (done_event),
    .error_event_o        (error_event)
  );

  // Placeholder output data. This is the replacement point for the real output
  // storage block once the SA datapath is available.
  sa_dummy_output i_dummy_output (
    .out_word_idx_i (out_word_idx),
    .config_i       (config_word),
    .out_rdata_o    (output_rdata)
  );

  // Output-window reads override register readback; all other reads come from
  // RegBank. Decoder error is reflected as APB PSLVERR.
  assign bus_rdata = out_rena ? output_rdata : reg_rdata;
  assign bus_err   = dec_err;

  wire _unused = &{1'b0, ss_ctrl_i, done_event, error_event, PADDR[31:12], 1'b0};

endmodule
