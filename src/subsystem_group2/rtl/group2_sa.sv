`timescale 1ns/1ps

module group2_sa (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    input  logic         weight_valid_i,
    input  logic [4:0]   weight_col_i,
    input  logic [127:0] weight_data_i,

    input  logic         act_valid_i,
    output logic         act_ready_o,
    input  logic [4:0]   act_row_i,
    input  logic [127:0] act_data_i,

    output logic         out_valid_o,
    input  logic         out_ready_i,
    output logic         out_bank_o,
    output logic [4:0]   out_row_o,
    output logic [255:0] out_data_o,
    output logic         idle_o
);

  localparam int ARRAY_H = 8;
  localparam int ARRAY_W = 16;
  localparam int TAG_STAGES = ARRAY_H + 1;

  logic         pending_q;
  logic         pending_bank_q;
  logic [4:0]   pending_row_q;
  logic [127:0] pending_data_q;
  logic         advance;
  logic         issue_valid;

  logic         act_valid_pipe_q [0:ARRAY_H-2];
  logic         act_bank_pipe_q  [0:ARRAY_H-2];
  logic [127:0] act_data_pipe_q  [0:ARRAY_H-2];

  logic         tag_valid_q [0:TAG_STAGES-1];
  logic         tag_bank_q  [0:TAG_STAGES-1];
  logic [4:0]   tag_row_q   [0:TAG_STAGES-1];

  logic signed [15:0] pe_sum [0:ARRAY_H-1][0:ARRAY_W-1];
  logic               pe_valid [0:ARRAY_H-1][0:ARRAY_W-1];

  logic pipe_busy;
  integer busy_idx;
  integer seq_idx;

  assign advance     = !out_valid_o || out_ready_i;
  assign issue_valid = pending_q;
  assign act_ready_o = advance && (!pending_q || pending_bank_q);
  assign out_valid_o = tag_valid_q[TAG_STAGES-1];
  assign out_bank_o  = tag_bank_q[TAG_STAGES-1];
  assign out_row_o   = tag_row_q[TAG_STAGES-1];

  always_comb begin
    pipe_busy = pending_q;
    for (busy_idx = 0; busy_idx < TAG_STAGES; busy_idx = busy_idx + 1) begin
      pipe_busy = pipe_busy | tag_valid_q[busy_idx];
    end
  end
  assign idle_o = !pipe_busy;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      pending_q      <= 1'b0;
      pending_bank_q <= 1'b0;
      pending_row_q  <= '0;
      pending_data_q <= '0;
      for (seq_idx = 0; seq_idx < ARRAY_H-1; seq_idx = seq_idx + 1) begin
        act_valid_pipe_q[seq_idx] <= 1'b0;
        act_bank_pipe_q[seq_idx]  <= 1'b0;
        act_data_pipe_q[seq_idx]  <= '0;
      end
      for (seq_idx = 0; seq_idx < TAG_STAGES; seq_idx = seq_idx + 1) begin
        tag_valid_q[seq_idx] <= 1'b0;
        tag_bank_q[seq_idx]  <= 1'b0;
        tag_row_q[seq_idx]   <= '0;
      end
    end else if (advance) begin
      if (pending_q) begin
        if (!pending_bank_q) begin
          pending_bank_q <= 1'b1;
        end else if (act_valid_i && act_ready_o) begin
          pending_q      <= 1'b1;
          pending_bank_q <= 1'b0;
          pending_row_q  <= act_row_i;
          pending_data_q <= act_data_i;
        end else begin
          pending_q <= 1'b0;
        end
      end else if (act_valid_i && act_ready_o) begin
        pending_q      <= 1'b1;
        pending_bank_q <= 1'b0;
        pending_row_q  <= act_row_i;
        pending_data_q <= act_data_i;
      end

      act_valid_pipe_q[0] <= issue_valid;
      act_bank_pipe_q[0]  <= pending_bank_q;
      act_data_pipe_q[0]  <= pending_data_q;
      for (seq_idx = 1; seq_idx < ARRAY_H-1; seq_idx = seq_idx + 1) begin
        act_valid_pipe_q[seq_idx] <= act_valid_pipe_q[seq_idx-1];
        act_bank_pipe_q[seq_idx]  <= act_bank_pipe_q[seq_idx-1];
        act_data_pipe_q[seq_idx]  <= act_data_pipe_q[seq_idx-1];
      end

      tag_valid_q[0] <= issue_valid;
      tag_bank_q[0]  <= pending_bank_q;
      tag_row_q[0]   <= pending_row_q;
      for (seq_idx = 1; seq_idx < TAG_STAGES; seq_idx = seq_idx + 1) begin
        tag_valid_q[seq_idx] <= tag_valid_q[seq_idx-1];
        tag_bank_q[seq_idx]  <= tag_bank_q[seq_idx-1];
        tag_row_q[seq_idx]   <= tag_row_q[seq_idx-1];
      end
    end
  end

  generate
    for (genvar row = 0; row < ARRAY_H; row = row + 1) begin : gen_rows
      for (genvar col = 0; col < ARRAY_W; col = col + 1) begin : gen_cols
        wire row_valid;
        wire row_bank;
        wire signed [15:0] row_data;
        wire signed [15:0] incoming_sum;

        if (row == 0) begin : gen_first_row
          assign row_valid    = issue_valid;
          assign row_bank     = pending_bank_q;
          assign row_data     = pending_data_q[row*16 +: 16];
          assign incoming_sum = 16'sd0;
        end else begin : gen_later_row
          assign row_valid    = act_valid_pipe_q[row-1];
          assign row_bank     = act_bank_pipe_q[row-1];
          assign row_data     = act_data_pipe_q[row-1][row*16 +: 16];
          assign incoming_sum = pe_sum[row-1][col];
        end

        group2_pe i_pe (
          .clk_i         (clk_i),
          .rst_ni        (rst_ni),
          .clear_i       (clear_i),
          .advance_i     (advance),
          .weight_load_i (weight_valid_i && (weight_col_i[3:0] == col[3:0])),
          .weight_bank_i (weight_col_i[4]),
          .weight_i      (weight_data_i[row*16 +: 16]),
          .data_valid_i  (row_valid),
          .data_bank_i   (row_bank),
          .data_i        (row_data),
          .sum_i         (incoming_sum),
          .sum_valid_o   (pe_valid[row][col]),
          .sum_o         (pe_sum[row][col])
        );
      end
    end

    for (genvar col = 0; col < ARRAY_W; col = col + 1) begin : gen_output
      assign out_data_o[col*16 +: 16] = pe_sum[ARRAY_H-1][col];
    end
  endgenerate

endmodule
