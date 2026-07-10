`timescale 1ns/1ps

module group2_frontend_tb;
  import group2_pkg::*;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         clear;
  logic [1:0]   precision;
  logic         word_valid;
  logic         word_ready;
  logic [31:0]  word;
  logic         vector_valid;
  logic         vector_ready;
  logic [127:0] vector_data;

  integer errors;
  integer expected [0:7];

  always #5 clk = ~clk;

  group2_input_frontend dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .clear_i        (clear),
    .precision_i    (precision),
    .word_valid_i   (word_valid),
    .word_ready_o   (word_ready),
    .word_i         (word),
    .vector_valid_o (vector_valid),
    .vector_ready_i (vector_ready),
    .vector_data_o  (vector_data)
  );

  task automatic clear_for_precision(input logic [1:0] dtype);
    begin
      @(negedge clk);
      precision = dtype;
      clear = 1'b1;
      @(negedge clk);
      clear = 1'b0;
    end
  endtask

  task automatic push_word(input logic [31:0] data);
    begin
      @(negedge clk);
      while (!word_ready) @(negedge clk);
      word = data;
      word_valid = 1'b1;
      @(negedge clk);
      word_valid = 1'b0;
      word = '0;
    end
  endtask

  task automatic check_vector(input logic [1:0] dtype);
    integer lane;
    integer timeout;
    begin
      timeout = 20;
      while (!vector_valid && timeout > 0) begin
        @(negedge clk);
        timeout = timeout - 1;
      end
      if (timeout == 0) begin
        $error("frontend timeout dtype=%0d", dtype);
        errors = errors + 1;
      end else begin
        for (lane = 0; lane < 8; lane = lane + 1) begin
          if (vector_data[lane*16 +: 16] !== expected[lane][15:0]) begin
            $error("dtype=%0d lane=%0d expected=%h got=%h", dtype, lane,
                   expected[lane][15:0], vector_data[lane*16 +: 16]);
            errors = errors + 1;
          end
        end
        vector_ready = 1'b1;
        @(negedge clk);
        vector_ready = 1'b0;
      end
    end
  endtask

  initial begin
    logic [31:0] packed_word;
    integer lane;

    errors = 0;
    clear = 1'b0;
    precision = DTYPE_INT4;
    word_valid = 1'b0;
    word = '0;
    vector_ready = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    expected[0] = -8;
    expected[1] = -1;
    expected[2] = 0;
    expected[3] = 1;
    expected[4] = 2;
    expected[5] = 3;
    expected[6] = 6;
    expected[7] = 7;
    clear_for_precision(DTYPE_INT4);
    packed_word = '0;
    for (lane = 0; lane < 8; lane = lane + 1) begin
      packed_word[lane*4 +: 4] = expected[lane][3:0];
    end
    push_word(packed_word);
    check_vector(DTYPE_INT4);

    expected[0] = -128;
    expected[1] = -1;
    expected[2] = 0;
    expected[3] = 127;
    expected[4] = -64;
    expected[5] = 1;
    expected[6] = 2;
    expected[7] = 63;
    clear_for_precision(DTYPE_INT8);
    packed_word = '0;
    for (lane = 0; lane < 4; lane = lane + 1) begin
      packed_word[lane*8 +: 8] = expected[lane][7:0];
    end
    push_word(packed_word);
    packed_word = '0;
    for (lane = 0; lane < 4; lane = lane + 1) begin
      packed_word[lane*8 +: 8] = expected[lane+4][7:0];
    end
    push_word(packed_word);
    check_vector(DTYPE_INT8);

    expected[0] = -32768;
    expected[1] = -1;
    expected[2] = 0;
    expected[3] = 32767;
    expected[4] = -12345;
    expected[5] = 12345;
    expected[6] = -2;
    expected[7] = 2;
    clear_for_precision(DTYPE_INT16);
    for (lane = 0; lane < 8; lane = lane + 2) begin
      packed_word[15:0] = expected[lane][15:0];
      packed_word[31:16] = expected[lane+1][15:0];
      push_word(packed_word);
    end
    check_vector(DTYPE_INT16);

    if (errors == 0) begin
      $display("GROUP2_FRONTEND_TB_PASS");
    end else begin
      $fatal(1, "GROUP2_FRONTEND_TB_FAIL errors=%0d", errors);
    end
    $finish;
  end

endmodule
