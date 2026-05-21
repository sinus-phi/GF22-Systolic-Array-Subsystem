`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Firmware-style APB testbench for the integrated SA subsystem.
//
// This test intentionally drives only the APB-visible interface, matching the
// sequence firmware would use after the subsystem is mapped into an FPGA
// bitstream:
//   1. Configure one tile.
//   2. Load one weight tile.
//   3. Stream several activation batches without reloading weights.
  //   4. Copy each output tile, release the hardware buffer immediately, then
  //      verify the copied data.
//
// Passing this test demonstrates the current blocking output policy and the
// weight-stationary contract: weights remain valid across release_output while
// batch_count still has work left.
//-----------------------------------------------------------------------------

module tb_subsystem_weight_stationary;

  import subsystem_pkg::*;

  localparam logic [31:0] REG_CONTROL      = 32'h0000_0000;
  localparam logic [31:0] REG_STATUS       = 32'h0000_0004;
  localparam logic [31:0] REG_CONFIG       = 32'h0000_0008;
  localparam logic [31:0] REG_OUTPUT_WORDS = 32'h0000_0014;
  localparam logic [31:0] WEIGHT_BASE      = 32'h0000_0100;
  localparam logic [31:0] ACT_BASE         = 32'h0000_0200;
  localparam logic [31:0] OUTPUT_BASE      = 32'h0000_0400;

  localparam logic [31:0] CTRL_LOAD_WEIGHTS   = 32'h0000_0001;
  localparam logic [31:0] CTRL_RELEASE_OUTPUT = 32'h0000_0002;
  localparam logic [31:0] CTRL_CLEAR_DONE     = 32'h0000_0004;
  localparam logic [31:0] CTRL_CLEAR_ERROR    = 32'h0000_0008;
  localparam logic [31:0] CTRL_SOFT_RESET     = 32'h0000_0010;

  localparam logic [1:0] DTYPE_INT4 = 2'd0;

  localparam int TILE_M = 2;
  localparam int TILE_N = 3;
  localparam int TILE_K = 4;
  localparam int BATCHES = 3;
  localparam int EXPECTED_OUTPUT_WORDS = TILE_M * TILE_N * 2;

  logic        clk;
  logic        rst_n;
  logic [31:0] paddr;
  logic        penable;
  logic        psel;
  logic [31:0] pwdata;
  logic        pwrite;
  logic [31:0] prdata;
  logic        pready;
  logic        pslverr;
  logic        irq;
  logic [15:0] pmod_gpo;
  logic [15:0] pmod_gpio_oe;

  int errors;

  int signed weights [0:TILE_K-1][0:TILE_N-1];
  int signed acts [0:BATCHES-1][0:TILE_M-1][0:TILE_K-1];
  logic [31:0] output_low_copy [0:TILE_M-1][0:TILE_N-1];
  logic [31:0] output_high_copy [0:TILE_M-1][0:TILE_N-1];

  always #5 clk = ~clk;

  subsystem_topmodule dut (
    .PADDR        (paddr),
    .PENABLE      (penable),
    .PSEL         (psel),
    .PWDATA       (pwdata),
    .PWRITE       (pwrite),
    .PRDATA       (prdata),
    .PREADY       (pready),
    .PSLVERR      (pslverr),
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .irq_en_i     (1'b1),
    .ss_ctrl_i    (8'd0),
    .pmod_gpi     (16'd0),
    .irq_o        (irq),
    .pmod_gpo     (pmod_gpo),
    .pmod_gpio_oe (pmod_gpio_oe)
  );

  function automatic logic [31:0] make_cfg(
      input logic [1:0] act_precision,
      input logic [1:0] weight_precision,
      input int unsigned tile_m,
      input int unsigned tile_n,
      input int unsigned tile_k,
      input int unsigned batch_count
  );
    begin
      make_cfg = 32'd0;
      make_cfg[1:0]   = act_precision;
      make_cfg[3:2]   = weight_precision;
      make_cfg[8:4]   = tile_m[4:0];
      make_cfg[13:9]  = tile_n[4:0];
      make_cfg[18:14] = tile_k[4:0];
      make_cfg[24:19] = batch_count[5:0];
    end
  endfunction

  function automatic logic [3:0] int4_bits(input int signed value);
    begin
      int4_bits = value[3:0];
    end
  endfunction

  function automatic logic [31:0] pack_int4_k4(
      input int signed e0,
      input int signed e1,
      input int signed e2,
      input int signed e3
  );
    begin
      // tile_k is 4 in this test.  The frontend is expected to ignore the high
      // nibbles of this word and zero-pad physical lanes 4..7.
      pack_int4_k4 = 32'd0;
      pack_int4_k4[3:0]   = int4_bits(e0);
      pack_int4_k4[7:4]   = int4_bits(e1);
      pack_int4_k4[11:8]  = int4_bits(e2);
      pack_int4_k4[15:12] = int4_bits(e3);
    end
  endfunction

  function automatic logic [2:0] phase_of(input logic [31:0] status);
    begin
      phase_of = status[9:7];
    end
  endfunction

  function automatic logic weights_valid_of(input logic [31:0] status);
    begin
      weights_valid_of = status[3];
    end
  endfunction

  function automatic logic output_valid_of(input logic [31:0] status);
    begin
      output_valid_of = status[4];
    end
  endfunction

  function automatic logic done_sticky_of(input logic [31:0] status);
    begin
      done_sticky_of = status[2];
    end
  endfunction

  function automatic logic error_sticky_of(input logic [31:0] status);
    begin
      error_sticky_of = status[1];
    end
  endfunction

  function automatic logic overflow_sticky_of(input logic [31:0] status);
    begin
      overflow_sticky_of = status[14];
    end
  endfunction

  function automatic logic [31:0] output_words_of(input logic [31:0] status);
    begin
      output_words_of = {24'd0, status[23:16]};
    end
  endfunction

  function automatic longint signed expected_acc(
      input int unsigned batch,
      input int unsigned row,
      input int unsigned col
  );
    longint signed acc;
    begin
      acc = 0;
      for (int k = 0; k < TILE_K; k++) begin
        acc += longint'(acts[batch][row][k]) * longint'(weights[k][col]);
      end
      expected_acc = acc;
    end
  endfunction

  function automatic logic [63:0] signed64_bits(input longint signed value);
    begin
      signed64_bits = value;
    end
  endfunction

  task automatic fail(input string msg);
    begin
      $display("WEIGHT_STATIONARY_ERROR,%s", msg);
      errors++;
    end
  endtask

  task automatic expect_eq32(
      input string name,
      input logic [31:0] got,
      input logic [31:0] exp
  );
    begin
      if (got !== exp) begin
        $display("WEIGHT_STATIONARY_ERROR,%s,got=0x%08h,exp=0x%08h",
                 name, got, exp);
        errors++;
      end
    end
  endtask

  task automatic apb_write(input logic [31:0] addr, input logic [31:0] data);
    int timeout;
    begin
      @(negedge clk);
      paddr   = addr;
      pwdata  = data;
      pwrite  = 1'b1;
      psel    = 1'b1;
      penable = 1'b0;

      @(negedge clk);
      penable = 1'b1;
      timeout = 0;

      do begin
        @(negedge clk);
        timeout++;
        if (timeout > 50) begin
          fail($sformatf("PREADY timeout on APB write addr=0x%08h", addr));
          break;
        end
      end while (!pready);

      if (pslverr) begin
        fail($sformatf("unexpected PSLVERR on APB write addr=0x%08h data=0x%08h",
                       addr, data));
      end

      psel    = 1'b0;
      penable = 1'b0;
      pwrite  = 1'b0;
      pwdata  = 32'd0;
    end
  endtask

  task automatic apb_read(input logic [31:0] addr, output logic [31:0] data);
    int timeout;
    begin
      @(negedge clk);
      paddr   = addr;
      pwrite  = 1'b0;
      psel    = 1'b1;
      penable = 1'b0;

      @(negedge clk);
      penable = 1'b1;
      timeout = 0;

      do begin
        @(negedge clk);
        timeout++;
        if (timeout > 50) begin
          fail($sformatf("PREADY timeout on APB read addr=0x%08h", addr));
          break;
        end
      end while (!pready);

      data = prdata;
      if (pslverr) begin
        fail($sformatf("unexpected PSLVERR on APB read addr=0x%08h", addr));
      end

      psel    = 1'b0;
      penable = 1'b0;
    end
  endtask

  task automatic wait_phase(input logic [2:0] exp_phase);
    logic [31:0] status;
    int timeout;
    begin
      timeout = 0;
      do begin
        apb_read(REG_STATUS, status);
        timeout++;
        if (timeout > 300) begin
          fail($sformatf("timeout waiting for phase %0d, last status=0x%08h",
                         exp_phase, status));
          return;
        end
      end while (phase_of(status) != exp_phase);
    end
  endtask

  task automatic wait_output_valid(input int unsigned batch);
    logic [31:0] status;
    int timeout;
    begin
      timeout = 0;
      do begin
        apb_read(REG_STATUS, status);
        timeout++;
        if (timeout > 500) begin
          fail($sformatf("timeout waiting for output_valid on batch %0d, status=0x%08h",
                         batch, status));
          return;
        end
      end while (!output_valid_of(status));

      if (!done_sticky_of(status)) begin
        fail($sformatf("done_sticky was not set when batch %0d output became valid",
                       batch));
      end
      if (!weights_valid_of(status)) begin
        fail($sformatf("weights_valid dropped before batch %0d output release",
                       batch));
      end
      if (error_sticky_of(status)) begin
        fail($sformatf("error_sticky set while waiting for batch %0d output",
                       batch));
      end
      if (overflow_sticky_of(status)) begin
        fail($sformatf("unexpected overflow in batch %0d", batch));
      end
      expect_eq32($sformatf("STATUS.output_words.batch%0d", batch),
                  output_words_of(status), EXPECTED_OUTPUT_WORDS[31:0]);
    end
  endtask

  task automatic init_matrices;
    begin
      // Weight tile W[k][n], K=4 and N=3.  Values fit signed INT4.
      weights[0][0] =  1; weights[1][0] = -2; weights[2][0] =  3; weights[3][0] = -1;
      weights[0][1] =  0; weights[1][1] =  4; weights[2][1] = -1; weights[3][1] =  2;
      weights[0][2] = -3; weights[1][2] =  1; weights[2][2] =  2; weights[3][2] =  1;

      // Batch 0 activation tile A[m][k], M=2 and K=4.
      acts[0][0][0] =  2; acts[0][0][1] =  1; acts[0][0][2] = -1; acts[0][0][3] =  3;
      acts[0][1][0] = -1; acts[0][1][1] =  2; acts[0][1][2] =  2; acts[0][1][3] =  0;

      // Batch 1 reuses the same weight tile with different activations.
      acts[1][0][0] =  1; acts[1][0][1] =  1; acts[1][0][2] =  1; acts[1][0][3] =  1;
      acts[1][1][0] =  3; acts[1][1][1] = -1; acts[1][1][2] =  0; acts[1][1][3] =  2;

      // Batch 2 adds another signed mix to catch stale/overwritten weight cases.
      acts[2][0][0] = -2; acts[2][0][1] =  0; acts[2][0][2] =  1; acts[2][0][3] = -1;
      acts[2][1][0] =  0; acts[2][1][1] = -3; acts[2][1][2] =  2; acts[2][1][3] =  1;
    end
  endtask

  task automatic stream_weight_tile_once;
    logic [31:0] word;
    begin
      for (int n = 0; n < TILE_N; n++) begin
        word = pack_int4_k4(
            weights[0][n],
            weights[1][n],
            weights[2][n],
            weights[3][n]
        );
        $display("WEIGHT_STREAM,col=%0d,word=0x%08h", n, word);
        apb_write(WEIGHT_BASE, word);
      end
    end
  endtask

  task automatic stream_activation_batch(input int unsigned batch);
    logic [31:0] word;
    begin
      for (int m = 0; m < TILE_M; m++) begin
        word = pack_int4_k4(
            acts[batch][m][0],
            acts[batch][m][1],
            acts[batch][m][2],
            acts[batch][m][3]
        );
        $display("ACT_STREAM,batch=%0d,row=%0d,word=0x%08h", batch, m, word);
        apb_write(ACT_BASE, word);
      end
    end
  endtask

  task automatic copy_output_batch(input int unsigned batch);
    logic [31:0] low_word;
    logic [31:0] high_word;
    int word_idx;
    begin
      wait_output_valid(batch);

      // Keep the output_valid critical section short. The single hardware
      // output buffer blocks the next activation batch until firmware releases
      // it, so this task only copies raw APB words into a testbench scratch
      // buffer. Reference checking happens after release_output.
      for (int m = 0; m < TILE_M; m++) begin
        for (int n = 0; n < TILE_N; n++) begin
          word_idx = ((m * TILE_N) + n) * 2;

          apb_read(OUTPUT_BASE + (word_idx * 4), low_word);
          apb_read(OUTPUT_BASE + ((word_idx + 1) * 4), high_word);
          output_low_copy[m][n] = low_word;
          output_high_copy[m][n] = high_word;
        end
      end
    end
  endtask

  task automatic verify_copied_output_batch(input int unsigned batch);
    logic [31:0] low_word;
    logic [31:0] high_word;
    logic [63:0] exp_bits;
    longint signed exp_value;
    begin
      for (int m = 0; m < TILE_M; m++) begin
        for (int n = 0; n < TILE_N; n++) begin
          exp_value = expected_acc(batch, m, n);
          exp_bits = signed64_bits(exp_value);
          low_word = output_low_copy[m][n];
          high_word = output_high_copy[m][n];

          $display("BATCH_RESULT,batch=%0d,row=%0d,col=%0d,value=%0d,low=0x%08h,high=0x%08h",
                   batch, m, n, exp_value, low_word, high_word);

          expect_eq32($sformatf("batch%0d[%0d,%0d].low", batch, m, n),
                      low_word, exp_bits[31:0]);
          expect_eq32($sformatf("batch%0d[%0d,%0d].high", batch, m, n),
                      high_word, exp_bits[63:32]);
        end
      end
    end
  endtask

  task automatic release_output_and_check(input int unsigned batch);
    logic [31:0] status;
    begin
      apb_write(REG_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE);

      if (batch + 1 < BATCHES) begin
        wait_phase(PH_BATCH_COMPUTE);
        apb_read(REG_STATUS, status);
        if (!weights_valid_of(status)) begin
          fail($sformatf("weights_valid dropped before next batch after batch %0d",
                         batch));
        end
        if (output_valid_of(status)) begin
          fail($sformatf("output_valid stayed high after releasing batch %0d",
                         batch));
        end
      end else begin
        wait_phase(PH_IDLE);
        apb_read(REG_STATUS, status);
        if (weights_valid_of(status)) begin
          fail("weights_valid stayed high after final batch release");
        end
        if (output_valid_of(status)) begin
          fail("output_valid stayed high after final batch release");
        end
      end
    end
  endtask

  initial begin
    logic [31:0] cfg;
    logic [31:0] status;
    logic [31:0] output_words;

    clk     = 1'b0;
    rst_n   = 1'b0;
    paddr   = 32'd0;
    penable = 1'b0;
    psel    = 1'b0;
    pwdata  = 32'd0;
    pwrite  = 1'b0;
    errors  = 0;

    init_matrices();

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    cfg = make_cfg(
        DTYPE_INT4, // activation precision
        DTYPE_INT4, // weight precision
        TILE_M,
        TILE_N,
        TILE_K,
        BATCHES
    );

    apb_write(REG_CONFIG, cfg);
    apb_write(REG_CONTROL, CTRL_LOAD_WEIGHTS);
    wait_phase(PH_LOAD_WEIGHTS);

    stream_weight_tile_once();
    wait_phase(PH_BATCH_COMPUTE);

    apb_read(REG_STATUS, status);
    if (!weights_valid_of(status)) begin
      fail("weights_valid was not set after weight-load settle");
    end

    apb_read(REG_OUTPUT_WORDS, output_words);
    expect_eq32("OUTPUT_WORDS before output_valid should read zero",
                output_words, 32'd0);

    for (int batch = 0; batch < BATCHES; batch++) begin
      stream_activation_batch(batch);
      copy_output_batch(batch);

      if (!irq) begin
        fail($sformatf("IRQ was not asserted after batch %0d output_valid",
                       batch));
      end

      release_output_and_check(batch);
      verify_copied_output_batch(batch);
    end

    // A soft reset at the end should be harmless after the final release.  This
    // mirrors firmware cleanup before starting a new independent transaction.
    apb_write(REG_CONTROL, CTRL_SOFT_RESET | CTRL_CLEAR_ERROR | CTRL_CLEAR_DONE);
    apb_read(REG_STATUS, status);
    if (phase_of(status) != PH_IDLE || weights_valid_of(status) || output_valid_of(status)) begin
      fail($sformatf("unexpected status after final soft reset: 0x%08h", status));
    end

    if (errors == 0) begin
      $display("WEIGHT_STATIONARY_TB_RESULT,pass");
    end else begin
      $display("WEIGHT_STATIONARY_TB_RESULT,fail,errors=%0d", errors);
      $fatal(1);
    end

    $finish;
  end

endmodule
