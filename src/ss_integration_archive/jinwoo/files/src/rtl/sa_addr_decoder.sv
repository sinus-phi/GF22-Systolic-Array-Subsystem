`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Local address decoder and access-policy gate.
//
// This block turns an accepted APB read/write into one local target pulse:
// register access, weight input, activation input, or output read. It also
// rejects accesses that are not legal for the current FSM phase.
//-----------------------------------------------------------------------------

module sa_addr_decoder (
    input  logic [11:0] local_addr_i,
    input  logic [31:0] bus_wdata_i,
    input  logic        bus_wena_i,
    input  logic        bus_rena_i,

    input  logic [2:0]  phase_i,
    input  logic        config_valid_i,
    input  logic        weights_valid_i,
    input  logic        output_valid_i,
    input  logic [31:0] output_words_i,

    output logic        reg_wena_o,
    output logic        reg_rena_o,
    output logic        weight_wena_o,
    output logic        act_wena_o,
    output logic        out_rena_o,
    output logic [5:0]  out_word_idx_o,
    output logic        dec_err_o,
    output logic [31:0] dec_error_code_o
);

  import sa_dummy_pkg::*;

  logic access;
  logic word_aligned;
  logic in_reg_region;
  logic in_weight_region;
  logic in_act_region;
  logic in_out_region;

  // 4 KiB local map:
  //   0x000-0x0FF registers
  //   0x100-0x1FF weight input words
  //   0x200-0x2FF activation input words
  //   0x400-0x4FF output read words
  assign access           = bus_wena_i | bus_rena_i;
  assign word_aligned     = (local_addr_i[1:0] == 2'b00);
  assign in_reg_region    = (local_addr_i[11:8] == 4'h0);
  assign in_weight_region = (local_addr_i[11:8] == 4'h1);
  assign in_act_region    = (local_addr_i[11:8] == 4'h2);
  assign in_out_region    = (local_addr_i[11:8] == 4'h4);
  assign out_word_idx_o   = local_addr_i[7:2];

  always_comb begin
    // Default is a rejected/no-op access; legal cases below assert exactly one
    // target pulse and leave dec_err_o low.
    reg_wena_o       = 1'b0;
    reg_rena_o       = 1'b0;
    weight_wena_o    = 1'b0;
    act_wena_o       = 1'b0;
    out_rena_o       = 1'b0;
    dec_err_o        = 1'b0;
    dec_error_code_o = ERR_NONE;

    if (access && !word_aligned) begin
      dec_err_o        = 1'b1;
      dec_error_code_o = ERR_UNALIGNED;
    end

    else if (bus_wena_i) begin
      if (in_weight_region) begin
        // Weight words are accepted only during the explicit load phase.
        if (phase_i == PH_LOAD_WEIGHTS) begin
          weight_wena_o = 1'b1;
        end else begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end
      end

      else if (in_act_region) begin
        // Activation words are accepted only after a valid weight context
        // exists and the FSM is ready to compute a batch.
        if ((phase_i == PH_BATCH_COMPUTE) && weights_valid_i) begin
          act_wena_o = 1'b1;
        end else begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end
      end

      else if (in_reg_region) begin
        unique case (local_addr_i)
          OFF_CONTROL: begin
            // load_weights is the only command that starts a new transaction;
            // other command bits may be used for release/clear/reset.
            if (bus_wdata_i[0] && (phase_i != PH_IDLE)) begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_BAD_STATE;
            end else if (bus_wdata_i[0] && !config_valid_i) begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_INVALID_CONFIG;
            end else begin
              reg_wena_o = 1'b1;
            end
          end

          OFF_CONFIG: begin
            // CONFIG is locked once a weight context is active.
            if ((phase_i == PH_IDLE) && !weights_valid_i) begin
              reg_wena_o = 1'b1;
            end else begin
              dec_err_o        = 1'b1;
              dec_error_code_o = ERR_BAD_STATE;
            end
          end

          default: begin
            dec_err_o        = 1'b1;
            dec_error_code_o = ERR_BAD_ADDR;
          end
        endcase
      end

      else begin
        dec_err_o        = 1'b1;
        dec_error_code_o = ERR_BAD_ADDR;
      end
    end

    else if (bus_rena_i) begin
      if (in_out_region) begin
        // Output reads are controlled by output_valid, not by a DONE state.
        if (!output_valid_i) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_BAD_STATE;
        end else if ({26'd0, out_word_idx_o} >= output_words_i) begin
          dec_err_o        = 1'b1;
          dec_error_code_o = ERR_OUTPUT_RANGE;
        end else begin
          out_rena_o = 1'b1;
        end
      end

      else if (in_reg_region) begin
        unique case (local_addr_i)
          OFF_CONTROL,
          OFF_STATUS,
          OFF_CONFIG,
          OFF_PROGRESS,
          OFF_ERROR_CODE,
          OFF_OUTPUT_WORDS: begin
            reg_rena_o = 1'b1;
          end

          default: begin
            dec_err_o        = 1'b1;
            dec_error_code_o = ERR_BAD_ADDR;
          end
        endcase
      end

      else begin
        dec_err_o        = 1'b1;
        dec_error_code_o = ERR_BAD_ADDR;
      end
    end
  end

endmodule
