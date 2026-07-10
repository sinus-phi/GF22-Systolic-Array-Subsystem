`timescale 1ns/1ps

module group2_addr_decoder (
    input  logic [15:0] local_addr_i,
    input  logic [31:0] bus_wdata_i,
    input  logic        bus_wena_i,
    input  logic        bus_rena_i,

    input  logic [2:0]  phase_i,
    input  logic        busy_i,
    input  logic [31:0] config_i,
    input  logic        config_valid_i,
    input  logic        bias_ready_i,
    input  logic        context_valid_i,
    input  logic        context_match_i,
    input  logic        output_readable_i,
    input  logic [9:0]  output_words_i,
    input  logic [8:0]  weight_words_left_i,
    input  logic [8:0]  act_words_left_i,

    output logic        reg_wena_o,
    output logic        reg_rena_o,
    output logic        weight_wena_o,
    output logic        act_wena_o,
    output logic        bias_wena_o,
    output logic        bias_rena_o,
    output logic [3:0]  bias_word_idx_o,
    output logic        out_rena_o,
    output logic [8:0]  out_word_idx_o,
    output logic        dec_err_o,
    output logic [31:0] dec_error_code_o
);

  import group2_pkg::*;

  logic access;
  logic aligned;
  logic in_bias;
  logic in_output;
  logic [15:0] output_byte_offset;

  assign access = bus_wena_i | bus_rena_i;
  assign aligned = (local_addr_i[1:0] == 2'b00);
  assign in_bias = (local_addr_i >= OFF_BIAS_BASE) &&
                   (local_addr_i <= OFF_BIAS_LAST);
  assign in_output = (local_addr_i >= OFF_OUTPUT_BASE) &&
                     (local_addr_i <= OFF_OUTPUT_LAST);
  assign bias_word_idx_o = local_addr_i[5:2];
  assign output_byte_offset = local_addr_i - OFF_OUTPUT_BASE;
  assign out_word_idx_o = output_byte_offset[10:2];

  always_comb begin
    reg_wena_o       = 1'b0;
    reg_rena_o       = 1'b0;
    weight_wena_o    = 1'b0;
    act_wena_o       = 1'b0;
    bias_wena_o      = 1'b0;
    bias_rena_o      = 1'b0;
    out_rena_o       = 1'b0;
    dec_err_o        = 1'b0;
    dec_error_code_o = ERR_NONE;

    if (access && !aligned) begin
      dec_err_o        = 1'b1;
      dec_error_code_o = ERR_UNALIGNED;
    end else if (bus_wena_i) begin
      if (local_addr_i == OFF_CONTROL) begin
        if (!onehot_command(bus_wdata_i)) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_ILLEGAL_COMMAND;
        end else begin
          unique case (bus_wdata_i)
            CTRL_START_GEMM: begin
              if (busy_i) begin
                dec_err_o        = 1'b1;
                dec_error_code_o = ERR_BAD_STATE;
              end else if (!config_valid_i) begin
                dec_err_o        = 1'b1;
                dec_error_code_o = ERR_INVALID_CONFIG;
              end else if (cfg_bias_enable(config_i) && !bias_ready_i) begin
                dec_err_o        = 1'b1;
                dec_error_code_o = ERR_BIAS_NOT_READY;
              end else begin
                reg_wena_o = 1'b1;
              end
            end

            CTRL_START_GACC: begin
              if (busy_i || !context_valid_i || !context_match_i ||
                  (phase_i != PH_OUTPUT)) begin
                dec_err_o        = 1'b1;
                dec_error_code_o = ERR_INVALID_GACC_CONTEXT;
              end else begin
                reg_wena_o = 1'b1;
              end
            end

            CTRL_RELEASE_CONTEXT: begin
              if (busy_i || !context_valid_i || (phase_i != PH_OUTPUT)) begin
                dec_err_o        = 1'b1;
                dec_error_code_o = ERR_BAD_STATE;
              end else begin
                reg_wena_o = 1'b1;
              end
            end

            CTRL_CLEAR_DONE,
            CTRL_CLEAR_ERROR,
            CTRL_SOFT_RESET: reg_wena_o = 1'b1;

            default: begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_ILLEGAL_COMMAND;
            end
          endcase
        end
      end else if (local_addr_i == OFF_CONFIG) begin
        if (busy_i || context_valid_i || (phase_i != PH_IDLE)) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end else if (!dtype_supported(bus_wdata_i[1:0]) ||
                     !dtype_supported(bus_wdata_i[3:2])) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_UNSUPPORTED_DTYPE;
        end else if (!config_valid(bus_wdata_i)) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_INVALID_CONFIG;
        end else begin
          reg_wena_o = 1'b1;
        end
      end else if (local_addr_i == OFF_WEIGHT_DATA) begin
        if ((phase_i == PH_WEIGHT) && (weight_words_left_i != 0)) begin
          weight_wena_o = 1'b1;
        end else if (busy_i) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_STREAM_COUNT;
        end else begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end
      end else if (local_addr_i == OFF_ACT_DATA) begin
        if ((phase_i == PH_ACTIVATION) && (act_words_left_i != 0)) begin
          act_wena_o = 1'b1;
        end else if (busy_i) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_STREAM_COUNT;
        end else begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end
      end else if (in_bias) begin
        if (!busy_i && !context_valid_i && (phase_i == PH_IDLE)) begin
          bias_wena_o = 1'b1;
        end else begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end
      end else begin
        dec_err_o        = 1'b1;
        dec_error_code_o = ERR_BAD_ADDR;
      end
    end else if (bus_rena_i) begin
      unique case (local_addr_i)
        OFF_STATUS,
        OFF_CONFIG,
        OFF_PROGRESS,
        OFF_ERROR_CODE,
        OFF_OUTPUT_WORDS,
        OFF_VERSION,
        OFF_CAPABILITY: reg_rena_o = 1'b1;
        default: begin
          if (in_bias) begin
            if (!busy_i && !context_valid_i && (phase_i == PH_IDLE)) begin
              bias_rena_o = 1'b1;
            end else begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_BAD_STATE;
            end
          end else if (in_output) begin
            if (!output_readable_i) begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_OUTPUT_NOT_READY;
            end else if ({1'b0, out_word_idx_o} >= output_words_i) begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_BAD_ADDR;
            end else begin
              out_rena_o = 1'b1;
            end
          end else begin
            dec_err_o        = 1'b1;
            dec_error_code_o = ERR_BAD_ADDR;
          end
        end
      endcase
    end
  end

endmodule
