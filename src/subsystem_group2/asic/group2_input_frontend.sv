`timescale 1ns/1ps

// Expands packed APB words into one vector of eight signed INT16 lanes.
module group2_input_frontend (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,
    input  logic [1:0]   precision_i,

    input  logic         word_valid_i,
    output logic         word_ready_o,
    input  logic [31:0]  word_i,

    output logic         vector_valid_o,
    input  logic         vector_ready_i,
    output logic [127:0] vector_data_o
);

  import group2_pkg::*;

  logic [31:0] fifo_q [0:1];
  logic        fifo_rd_q;
  logic        fifo_wr_q;
  logic [1:0]  fifo_count_q;
  logic [2:0]  word_index_q;
  logic [127:0] vector_q;
  logic         vector_valid_q;

  logic push;
  logic pop;
  logic [2:0] words_needed;
  logic [31:0] head_word;
  logic [127:0] vector_next;

  integer lane;

  // Two entries decouple APB writes from vector assembly.
  assign words_needed  = words_per_vector(precision_i);
  assign word_ready_o  = (fifo_count_q != 2'd2);
  assign push          = word_valid_i && word_ready_o;
  assign pop           = (fifo_count_q != 0) && !vector_valid_q;
  assign head_word     = fifo_q[fifo_rd_q];
  assign vector_valid_o = vector_valid_q;
  assign vector_data_o  = vector_q;

  // INT4 and INT8 lanes are sign-extended; INT16 lanes pass through.
  always_comb begin
    vector_next = vector_q;
    unique case (precision_i)
      DTYPE_INT4: begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
          vector_next[lane*16 +: 16] = {
            {12{head_word[lane*4 + 3]}},
            head_word[lane*4 +: 4]
          };
        end
      end

      DTYPE_INT8: begin
        for (lane = 0; lane < 4; lane = lane + 1) begin
          vector_next[(word_index_q*4+lane)*16 +: 16] =
              {{8{head_word[lane*8+7]}}, head_word[lane*8 +: 8]};
        end
      end

      DTYPE_INT16: begin
        for (lane = 0; lane < 2; lane = lane + 1) begin
          vector_next[(word_index_q*2+lane)*16 +: 16] =
              head_word[lane*16 +: 16];
        end
      end

      default: vector_next = '0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      fifo_rd_q      <= 1'b0;
      fifo_wr_q      <= 1'b0;
      fifo_count_q   <= '0;
      word_index_q   <= '0;
      vector_q       <= '0;
      vector_valid_q <= 1'b0;
    end else begin
      if (push) begin
        fifo_q[fifo_wr_q] <= word_i;
        fifo_wr_q         <= ~fifo_wr_q;
      end

      // Consume one packed word and publish after the last required word.
      if (pop) begin
        fifo_rd_q <= ~fifo_rd_q;
        vector_q  <= vector_next;
        if (word_index_q == (words_needed - 1'b1)) begin
          word_index_q   <= '0;
          vector_valid_q <= 1'b1;
        end else begin
          word_index_q <= word_index_q + 1'b1;
        end
      end

      if (vector_valid_q && vector_ready_i) begin
        vector_valid_q <= 1'b0;
        vector_q       <= '0;
      end

      unique case ({push, pop})
        2'b10: fifo_count_q <= fifo_count_q + 1'b1;
        2'b01: fifo_count_q <= fifo_count_q - 1'b1;
        default: fifo_count_q <= fifo_count_q;
      endcase
    end
  end

endmodule
