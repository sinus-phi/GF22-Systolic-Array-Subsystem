`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Student subsystem top module.
//
// This is the only module that should be instantiated by the provided template:
// Student_SS wrapper.  It connects the APB-visible frontend, compact register
// bank, single control FSM, input unpacker, systolic array, and output buffer.
//
// Control ownership is intentionally centralized in subsystem_sa_ctrl.  The
// other blocks either translate protocols, store state, move data, or expose
// output memory.  This keeps the subsystem easy to integrate and avoids
// multiple independent transaction FSMs.
//-----------------------------------------------------------------------------

module subsystem_topmodule (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        irq_en_i,
    input  logic [7:0]  ss_ctrl_i,
    input  logic [15:0] pmod_gpi,
    output logic        irq_o,
    output logic [15:0] pmod_gpo,
    output logic [15:0] pmod_gpio_oe
);

  import subsystem_pkg::*;

  // Datapath shape for the first integration target.  The firmware sees
  // precision-specific packed words, but the array itself always receives
  // sign-extended 32-bit operands and produces 64-bit accumulator values.
  localparam int DATA_WIDTH = 32;
  localparam int ACC_WIDTH = 64;
  localparam int ARRAY_H = SA_ARRAY_HEIGHT;
  localparam int ARRAY_W = SA_ARRAY_WIDTH;
  localparam int BUFF_ADDR_WIDTH = 10;
  localparam int OUTPUT_DATA_WIDTH = ACC_WIDTH * ARRAY_W;

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
  logic [7:0]  out_word_idx;
  logic        dec_err;
  logic [31:0] dec_error_code;
  logic        bus_ready;

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
  logic        overflow_sticky;
  logic        output_valid;
  logic        output_full;
  logic        output_blocked;
  logic [31:0] output_words;
  logic [31:0] error_code;
  logic [31:0] output_rdata;
  logic        output_read_valid;
  logic        output_read_pending;

  logic        weight_start;
  logic        activation_start;
  logic        load_settle_active;
  logic        output_drain_active;

  logic        input_vector_valid;
  logic [ARRAY_H*DATA_WIDTH-1:0] input_vector_data;
  logic [ARRAY_W-1:0] input_sa_load;
  logic        sa_en;
  logic [ARRAY_W-1:0] sa_load;
  logic [ARRAY_H*DATA_WIDTH-1:0] sa_i_data;
  logic [OUTPUT_DATA_WIDTH-1:0] sa_o_data;
  logic [ARRAY_W-1:0] sa_overflow;
  logic        mac_overflow;

  logic        out_wr_en;
  logic [BUFF_ADDR_WIDTH-1:0] out_wr_addr;
  logic [OUTPUT_DATA_WIDTH-1:0] out_wr_data;

  // APB timing is isolated here.  Downstream blocks see only local one-cycle
  // read/write pulses and a held response when the output buffer needs a wait
  // state for synchronous memory reads.
  subsystem_apb_if i_apb_if (
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

  // Decode the 4 KiB local address map and reject illegal accesses early.  This
  // is where firmware-visible ordering rules are enforced, for example:
  // weights only during LOAD_WEIGHTS and activations only during BATCH_COMPUTE.
  subsystem_addr_decoder i_addr_decoder (
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

  // Firmware-facing state lives here: CONFIG storage, CONTROL command pulses,
  // STATUS readback, ERROR_CODE readback, and the compact IRQ output.
  subsystem_regbank i_regbank (
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
    .overflow_sticky_i    (overflow_sticky),
    .output_valid_i       (output_valid),
    .output_full_i        (output_full),
    .output_blocked_i     (output_blocked),
    .output_words_i       (output_words),
    .error_code_i         (error_code),
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

  // Single transaction controller.  It owns the five visible phases and also
  // schedules the extra SA advance cycles needed for weight-load settle and
  // output drain/writeback.
  subsystem_sa_ctrl #(
    .ACC_WIDTH       (ACC_WIDTH),
    .ARRAY_HEIGHT    (ARRAY_H),
    .ARRAY_WIDTH     (ARRAY_W),
    .MAC_STAGES      (SA_MAC_STAGES),
    .BUFF_ADDR_WIDTH (BUFF_ADDR_WIDTH)
  ) i_sa_ctrl (
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
    .input_vector_valid_i (input_vector_valid),
    .mac_overflow_i       (mac_overflow),
    .config_i             (config_word),
    .config_valid_i       (config_valid),
    .weight_start_o       (weight_start),
    .activation_start_o   (activation_start),
    .load_settle_active_o (load_settle_active),
    .output_drain_active_o(output_drain_active),
    .out_wr_en_o          (out_wr_en),
    .out_wr_addr_o        (out_wr_addr),
    .phase_o              (phase),
    .weights_valid_o      (weights_valid),
    .done_sticky_o        (done_sticky),
    .error_sticky_o       (error_sticky),
    .overflow_sticky_o    (overflow_sticky),
    .output_valid_o       (output_valid),
    .output_full_o        (output_full),
    .output_blocked_o     (output_blocked),
    .output_words_o       (output_words),
    .error_code_o         (error_code)
  );

  // Convert APB words into one full ARRAY_H vector.  This block does not decide
  // when a transaction starts or ends; it only emits vector_valid and SA load
  // pulses when enough packed elements have arrived.
  subsystem_input_frontend #(
    .DATA_WIDTH      (DATA_WIDTH),
    .ARRAY_HEIGHT    (ARRAY_H),
    .ARRAY_WIDTH     (ARRAY_W)
  ) i_input_frontend (
    .clk_i                   (clk_i),
    .rst_ni                  (rst_ni),
    .clear_i                 (soft_reset_cmd),
    .weight_start_i          (weight_start),
    .activation_start_i      (activation_start),
    .phase_i                 (phase),
    .weight_precision_i      (config_word[3:2]),
    .activation_precision_i  (config_word[1:0]),
    .tile_k_i                (cfg_tile_k(config_word)),
    .word_i                  (bus_wdata),
    .weight_word_valid_i     (weight_wena),
    .activation_word_valid_i (act_wena),
    .vector_valid_o          (input_vector_valid),
    .vector_data_o           (input_vector_data),
    .sa_load_o               (input_sa_load)
  );

  // SA advances for three reasons: a real input vector arrived, the final
  // weight-load wave still needs time to settle through the skewed path, or
  // remaining partial sums need to be drained after the last activation vector.
  assign sa_en     = input_vector_valid | load_settle_active | output_drain_active;
  assign sa_load   = input_vector_valid ? input_sa_load : '0;
  assign sa_i_data = input_vector_valid ? input_vector_data : '0;

  // The systolic array remains datapath-only.  It has no visibility into APB,
  // CONFIG fields, or firmware state.
  subsystem_sa #(
    .DATA_WIDTH   (DATA_WIDTH),
    .ACC_WIDTH    (ACC_WIDTH),
    .MAC_STAGES   (SA_MAC_STAGES),
    .ARRAY_HEIGHT (ARRAY_H),
    .ARRAY_WIDTH  (ARRAY_W)
  ) i_sa (
    .clk    (clk_i),
    .rst_n  (rst_ni),
    .en     (sa_en),
    .load   (sa_load),
    .i_data (sa_i_data),
    .o_data (sa_o_data),
    .o_overflow (sa_overflow)
  );

  assign mac_overflow = |sa_overflow;
  assign out_wr_data = sa_o_data;

  // The output buffer stores row-wide SA results.  APB reads expose a compact
  // stream containing only tile_m x tile_n accumulators, split into low/high
  // 32-bit words.
  subsystem_output_buffer #(
    .ACC_WIDTH       (ACC_WIDTH),
    .ARRAY_HEIGHT    (ARRAY_H),
    .ARRAY_WIDTH     (ARRAY_W),
    .BUFF_ADDR_WIDTH (BUFF_ADDR_WIDTH)
  ) i_output_buffer (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .clear_i      (soft_reset_cmd | release_output_cmd),
    .wr_en_i      (out_wr_en),
    .wr_addr_i    (out_wr_addr),
    .wr_data_i    (out_wr_data),
    .rd_req_i     (out_rena),
    .tile_n_i     (cfg_tile_n(config_word)),
    .rd_word_idx_i(out_word_idx),
    .rd_data_o    (output_rdata),
    .rd_valid_o   (output_read_valid)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      output_read_pending <= 1'b0;
    end else if (soft_reset_cmd) begin
      output_read_pending <= 1'b0;
    end else if (out_rena) begin
      output_read_pending <= 1'b1;
    end else if (output_read_pending && output_read_valid) begin
      output_read_pending <= 1'b0;
    end
  end

  // Register reads/writes are ready immediately after the adapter issues the
  // local pulse. Output reads model a synchronous memory response, so APB is
  // held until the output buffer returns rd_valid_o.
  assign bus_ready = out_rena ? 1'b0 :
                     (output_read_pending ? output_read_valid : 1'b1);
  assign bus_rdata = (output_read_pending || output_read_valid) ?
                     output_rdata : reg_rdata;
  assign bus_err   = dec_err;

  wire _unused = &{1'b0, ss_ctrl_i, PADDR[31:12], 1'b0};

endmodule
