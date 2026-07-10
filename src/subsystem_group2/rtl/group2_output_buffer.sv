`timescale 1ns/1ps

module group2_output_buffer (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,
    input  logic         gacc_i,

    input  logic         beat_valid_i,
    output logic         beat_ready_o,
    input  logic         beat_bank_i,
    input  logic [4:0]   beat_row_i,
    input  logic [255:0] beat_data_i,
    output logic         beat_commit_o,

    input  logic         bias_enable_i,
    input  logic [511:0] bias_data_i,

    input  logic         rd_req_i,
    input  logic [8:0]   rd_word_idx_i,
    output logic [31:0]  rd_data_o,
    output logic         rd_ready_o
);

  logic         pending_q [0:1];
  logic [4:0]   pending_row_q [0:1];
  logic [255:0] pending_data_q [0:1];

  logic         sram_en [0:1];
  logic         sram_we [0:1];
  logic [4:0]   sram_addr [0:1];
  logic [255:0] sram_wdata [0:1];
  logic [255:0] sram_rdata [0:1];
  logic         sram_rvalid [0:1];

  logic [255:0] gacc_sum [0:1];
  logic         commit [0:1];
  logic         beat_accept;

  logic         cache_valid_q;
  logic [4:0]   cache_row_q;
  logic [511:0] cache_data_q;
  logic         cache_fill_q;
  logic [4:0]   cache_fill_row_q;
  logic         prefetch_q;
  logic [4:0]   prefetch_row_q;
  logic         cache_issue;
  logic [4:0]   cache_issue_row;
  logic [4:0]   request_row;
  logic [3:0]   request_pair;
  logic         cache_hit;

  logic signed [15:0] result_lo;
  logic signed [15:0] result_hi;
  logic signed [15:0] bias_lo;
  logic signed [15:0] bias_hi;

  integer add_lane;
  integer add_bank;
  integer cmd_bank;
  integer seq_bank;

  assign request_row  = rd_word_idx_i[8:4];
  assign request_pair = rd_word_idx_i[3:0];
  assign cache_hit    = cache_valid_q && (cache_row_q == request_row);
  assign rd_ready_o   = rd_req_i && cache_hit;

  always_comb begin
    result_lo = cache_data_q[(request_pair*32) +: 16];
    result_hi = cache_data_q[(request_pair*32+16) +: 16];
    bias_lo   = bias_data_i[(request_pair*32) +: 16];
    bias_hi   = bias_data_i[(request_pair*32+16) +: 16];
    if (bias_enable_i) begin
      result_lo = result_lo + bias_lo;
      result_hi = result_hi + bias_hi;
    end
    rd_data_o = {result_hi, result_lo};
  end

  assign cache_issue = !cache_fill_q &&
                       (prefetch_q || (rd_req_i && !cache_hit));
  assign cache_issue_row = prefetch_q ? prefetch_row_q : request_row;

  always_comb begin
    for (add_bank = 0; add_bank < 2; add_bank = add_bank + 1) begin
      gacc_sum[add_bank] = '0;
      for (add_lane = 0; add_lane < 16; add_lane = add_lane + 1) begin
        gacc_sum[add_bank][add_lane*16 +: 16] =
            pending_data_q[add_bank][add_lane*16 +: 16] +
            sram_rdata[add_bank][add_lane*16 +: 16];
      end
    end
  end

  always_comb begin
    beat_ready_o = !pending_q[beat_bank_i] && !cache_fill_q && !prefetch_q;
    beat_accept  = beat_valid_i && beat_ready_o;
    commit[0]    = 1'b0;
    commit[1]    = 1'b0;

    for (cmd_bank = 0; cmd_bank < 2; cmd_bank = cmd_bank + 1) begin
      sram_en[cmd_bank]    = 1'b0;
      sram_we[cmd_bank]    = 1'b0;
      sram_addr[cmd_bank]  = '0;
      sram_wdata[cmd_bank] = '0;

      if (gacc_i && pending_q[cmd_bank] && sram_rvalid[cmd_bank]) begin
        sram_en[cmd_bank]    = 1'b1;
        sram_we[cmd_bank]    = 1'b1;
        sram_addr[cmd_bank]  = pending_row_q[cmd_bank];
        sram_wdata[cmd_bank] = gacc_sum[cmd_bank];
        commit[cmd_bank]     = 1'b1;
      end else if (beat_accept && (beat_bank_i == 1'(cmd_bank))) begin
        sram_en[cmd_bank]   = 1'b1;
        sram_addr[cmd_bank] = beat_row_i;
        if (gacc_i) begin
          sram_we[cmd_bank] = 1'b0;
        end else begin
          sram_we[cmd_bank]    = 1'b1;
          sram_wdata[cmd_bank] = beat_data_i;
          commit[cmd_bank]     = 1'b1;
        end
      end else if (cache_issue) begin
        sram_en[cmd_bank]   = 1'b1;
        sram_we[cmd_bank]   = 1'b0;
        sram_addr[cmd_bank] = cache_issue_row;
      end
    end
  end

  assign beat_commit_o = commit[0] | commit[1];

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      pending_q[0]       <= 1'b0;
      pending_q[1]       <= 1'b0;
      pending_row_q[0]   <= '0;
      pending_row_q[1]   <= '0;
      pending_data_q[0]  <= '0;
      pending_data_q[1]  <= '0;
      cache_valid_q      <= 1'b0;
      cache_row_q        <= '0;
      cache_data_q       <= '0;
      cache_fill_q       <= 1'b0;
      cache_fill_row_q   <= '0;
      prefetch_q         <= 1'b0;
      prefetch_row_q     <= '0;
    end else begin
      for (seq_bank = 0; seq_bank < 2; seq_bank = seq_bank + 1) begin
        if (beat_accept && gacc_i && (beat_bank_i == 1'(seq_bank))) begin
          pending_q[seq_bank]      <= 1'b1;
          pending_row_q[seq_bank]  <= beat_row_i;
          pending_data_q[seq_bank] <= beat_data_i;
        end
        if (commit[seq_bank] && gacc_i) begin
          pending_q[seq_bank] <= 1'b0;
        end
      end

      if (cache_issue) begin
        cache_fill_q     <= 1'b1;
        cache_fill_row_q <= cache_issue_row;
        cache_valid_q    <= 1'b0;
        prefetch_q       <= 1'b0;
      end

      if (cache_fill_q && sram_rvalid[0] && sram_rvalid[1]) begin
        cache_data_q  <= {sram_rdata[1], sram_rdata[0]};
        cache_row_q   <= cache_fill_row_q;
        cache_valid_q <= 1'b1;
        cache_fill_q  <= 1'b0;
      end

      if (rd_req_i && rd_ready_o && (request_pair == 4'd15) &&
          (request_row != 5'd31)) begin
        cache_valid_q  <= 1'b0;
        prefetch_q     <= 1'b1;
        prefetch_row_q <= request_row + 1'b1;
      end
    end
  end

  generate
    for (genvar b = 0; b < 2; b = b + 1) begin : gen_banks
      group2_sram_32x128 i_sram_lo (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .en_i     (sram_en[b]),
        .we_i     (sram_we[b]),
        .addr_i   (sram_addr[b]),
        .wdata_i  (sram_wdata[b][127:0]),
        .rdata_o  (sram_rdata[b][127:0]),
        .rvalid_o (sram_rvalid[b])
      );

      logic unused_rvalid_hi;
      group2_sram_32x128 i_sram_hi (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .en_i     (sram_en[b]),
        .we_i     (sram_we[b]),
        .addr_i   (sram_addr[b]),
        .wdata_i  (sram_wdata[b][255:128]),
        .rdata_o  (sram_rdata[b][255:128]),
        .rvalid_o (unused_rvalid_hi)
      );
    end
  endgenerate

endmodule
