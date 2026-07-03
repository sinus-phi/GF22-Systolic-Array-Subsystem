`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Compact firmware-visible register bank.
//
// RegBank stores the current CONFIG word, converts CONTROL writes into
// one-cycle command pulses, and exposes FSM/output state through STATUS and
// PROGRESS. Debug-only registers are intentionally omitted in this skeleton.
//-----------------------------------------------------------------------------

module sa_regbank (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic [11:0] local_addr_i,
    input  logic [31:0] bus_wdata_i,
    input  logic        reg_wena_i,
    input  logic        reg_rena_i,

    input  logic [2:0]  phase_i,
    input  logic        weights_valid_i,
    input  logic        done_sticky_i,
    input  logic        error_sticky_i,
    input  logic        output_valid_i,
    input  logic        output_full_i,
    input  logic        output_blocked_i,
    input  logic [1:0]  output_valid_count_i,
    input  logic [31:0] output_words_i,
    input  logic [31:0] error_code_i,
    input  logic [31:0] progress_current_i,
    input  logic [31:0] progress_target_i,
    input  logic [31:0] batch_remaining_i,
    input  logic [1:0]  progress_kind_i,

    input  logic        irq_en_i,
    input  logic [15:0] pmod_gpi,

    output logic [31:0] config_o,
    output logic        config_valid_o,
    output logic        load_weights_cmd_o,
    output logic        release_output_cmd_o,
    output logic        clear_done_cmd_o,
    output logic        clear_error_cmd_o,
    output logic        soft_reset_cmd_o,
    output logic [31:0] reg_rdata_o,
    output logic        irq_o,
    output logic [15:0] pmod_gpo,
    output logic [15:0] pmod_gpio_oe
);

  import sa_dummy_pkg::*;

  logic [31:0] config_q;
  logic [31:0] status_word;
  logic [31:0] progress_word;
  logic        control_write;

  // CONTROL is command-only. Bits are not stored; each accepted write creates
  // pulses consumed by the FSM/output control path.
  assign control_write        = reg_wena_i && (local_addr_i == OFF_CONTROL);
  assign load_weights_cmd_o   = control_write && bus_wdata_i[0];
  assign release_output_cmd_o = control_write && bus_wdata_i[1];
  assign clear_done_cmd_o     = control_write && bus_wdata_i[2];
  assign clear_error_cmd_o    = control_write && bus_wdata_i[3];
  assign soft_reset_cmd_o     = control_write && bus_wdata_i[4];

  assign config_o       = config_q;
  assign config_valid_o = config_valid(config_q);

  // STATUS is packed to keep the first integration register map small while
  // still exposing phase, sticky flags, and output-slot state.
  assign status_word = {
    9'd0,
    output_valid_i ? output_words_i[6:0] : 7'd0, // bits 22:16
    output_valid_count_i,                        // bits 15:14
    error_code_i[3:0],                           // bits 13:10
    phase_i,                                     // bits 9:7
    output_blocked_i,                            // bit 6
    output_full_i,                               // bit 5
    output_valid_i,                              // bit 4
    weights_valid_i,                             // bit 3
    done_sticky_i,                               // bit 2
    error_sticky_i,                              // bit 1
    ((phase_i == PH_LOAD_WEIGHTS) ||
     (phase_i == PH_BATCH_COMPUTE) ||
     (phase_i == PH_DRAIN_WRITEBACK))            // bit 0
  };

  // PROGRESS shows the active FSM counter without exposing separate debug
  // count registers for weight, activation, and drain.
  assign progress_word = {
    7'd0,
    progress_kind_i,           // bits 24:23
    batch_remaining_i[4:0],    // bits 22:18
    progress_target_i[8:0],    // bits 17:9
    progress_current_i[8:0]    // bits 8:0
  };

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      config_q <= 32'd0;
    end else begin
      // Soft reset clears the run configuration together with FSM state.
      if (soft_reset_cmd_o) begin
        config_q <= 32'd0;
      end else if (reg_wena_i && (local_addr_i == OFF_CONFIG)) begin
        config_q <= bus_wdata_i;
      end
    end
  end

  always_comb begin
    // Combinational readback keeps APB reads single-cycle in the dummy model.
    unique case (local_addr_i)
      OFF_CONTROL:      reg_rdata_o = 32'd0;
      OFF_STATUS:       reg_rdata_o = status_word;
      OFF_CONFIG:       reg_rdata_o = config_q;
      OFF_PROGRESS:     reg_rdata_o = progress_word;
      OFF_ERROR_CODE:   reg_rdata_o = error_code_i;
      OFF_OUTPUT_WORDS: reg_rdata_o = output_valid_i ? output_words_i : 32'd0;
      default:          reg_rdata_o = 32'd0;
    endcase
  end

  // Compact v1 uses SoC-level irq_en_i directly; local IRQ mask registers are
  // deferred until the debug/control map grows.
  assign irq_o = irq_en_i && (done_sticky_i || error_sticky_i);

  // Debug sideband is intentionally inactive in this compact control-plane
  // skeleton. Keep the ports tied off so the SoC wrapper contract stays stable.
  assign pmod_gpo     = 16'd0;
  assign pmod_gpio_oe = 16'd0;

  wire _unused_regbank = &{1'b0, reg_rena_i, pmod_gpi, 1'b0};

endmodule
