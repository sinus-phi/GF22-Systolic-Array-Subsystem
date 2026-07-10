`timescale 1ns/1ps

module group2_regbank (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic [15:0]  local_addr_i,
    input  logic [31:0]  bus_wdata_i,
    input  logic         reg_wena_i,
    input  logic         reg_rena_i,
    input  logic         bias_wena_i,
    input  logic         bias_rena_i,
    input  logic [3:0]   bias_word_idx_i,

    input  logic         busy_i,
    input  logic         error_sticky_i,
    input  logic         done_sticky_i,
    input  logic         context_valid_i,
    input  logic         output_readable_i,
    input  logic [2:0]   phase_i,
    input  logic [31:0]  progress_i,
    input  logic [31:0]  error_code_i,
    input  logic [9:0]   output_words_i,
    input  logic         irq_en_i,
    input  logic [15:0]  pmod_gpi,

    output logic [31:0]  config_o,
    output logic         config_valid_o,
    output logic [511:0] bias_data_o,
    output logic         bias_ready_o,
    output logic         start_gemm_cmd_o,
    output logic         start_gacc_cmd_o,
    output logic         clear_done_cmd_o,
    output logic         clear_error_cmd_o,
    output logic         soft_reset_cmd_o,
    output logic         release_context_cmd_o,
    output logic [31:0]  reg_rdata_o,
    output logic         irq_o,
    output logic [15:0]  pmod_gpo,
    output logic [15:0]  pmod_gpio_oe
);

  import group2_pkg::*;

  logic [31:0] config_q;
  logic [511:0] bias_q;
  logic [15:0] bias_valid_q;

  assign config_o       = config_q;
  assign config_valid_o = config_valid(config_q);
  assign bias_data_o    = bias_q;
  assign bias_ready_o   = &bias_valid_q;
  assign irq_o          = irq_en_i && (done_sticky_i || error_sticky_i);
  assign pmod_gpo       = 16'd0;
  assign pmod_gpio_oe   = 16'd0;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      config_q             <= '0;
      bias_q               <= '0;
      bias_valid_q         <= '0;
      start_gemm_cmd_o     <= 1'b0;
      start_gacc_cmd_o     <= 1'b0;
      clear_done_cmd_o     <= 1'b0;
      clear_error_cmd_o    <= 1'b0;
      soft_reset_cmd_o     <= 1'b0;
      release_context_cmd_o <= 1'b0;
    end else begin
      start_gemm_cmd_o      <= 1'b0;
      start_gacc_cmd_o      <= 1'b0;
      clear_done_cmd_o      <= 1'b0;
      clear_error_cmd_o     <= 1'b0;
      soft_reset_cmd_o      <= 1'b0;
      release_context_cmd_o <= 1'b0;

      if (reg_wena_i) begin
        unique case (local_addr_i)
          OFF_CONTROL: begin
            start_gemm_cmd_o      <= (bus_wdata_i == CTRL_START_GEMM);
            start_gacc_cmd_o      <= (bus_wdata_i == CTRL_START_GACC);
            clear_done_cmd_o      <= (bus_wdata_i == CTRL_CLEAR_DONE);
            clear_error_cmd_o     <= (bus_wdata_i == CTRL_CLEAR_ERROR);
            soft_reset_cmd_o      <= (bus_wdata_i == CTRL_SOFT_RESET);
            release_context_cmd_o <= (bus_wdata_i == CTRL_RELEASE_CONTEXT);
            if (bus_wdata_i == CTRL_SOFT_RESET) begin
              config_q     <= '0;
              bias_valid_q <= '0;
            end
          end
          OFF_CONFIG: config_q <= bus_wdata_i;
          default: ;
        endcase
      end

      if (bias_wena_i) begin
        bias_q[bias_word_idx_i*32 +: 32] <= bus_wdata_i;
        bias_valid_q[bias_word_idx_i] <= 1'b1;
      end
    end
  end

  always_comb begin
    reg_rdata_o = 32'd0;
    if (bias_rena_i) begin
      reg_rdata_o = bias_q[bias_word_idx_i*32 +: 32];
    end else if (reg_rena_i) begin
      unique case (local_addr_i)
        OFF_STATUS: begin
          reg_rdata_o[0]   = busy_i;
          reg_rdata_o[1]   = error_sticky_i;
          reg_rdata_o[2]   = done_sticky_i;
          reg_rdata_o[3]   = context_valid_i;
          reg_rdata_o[4]   = output_readable_i;
          reg_rdata_o[7:5] = phase_i;
        end
        OFF_CONFIG:       reg_rdata_o = config_q;
        OFF_PROGRESS:     reg_rdata_o = progress_i;
        OFF_ERROR_CODE:   reg_rdata_o = error_code_i;
        OFF_OUTPUT_WORDS: reg_rdata_o = {22'd0, output_words_i};
        OFF_VERSION:      reg_rdata_o = VERSION;
        OFF_CAPABILITY:   reg_rdata_o = CAPABILITY;
        default:          reg_rdata_o = 32'd0;
      endcase
    end
  end

  wire _unused = &{1'b0, pmod_gpi, 1'b0};

endmodule
