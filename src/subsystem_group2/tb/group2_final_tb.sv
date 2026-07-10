`timescale 1ns/1ps

module group2_final_tb;
  import group2_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [15:0] paddr;
  logic penable;
  logic psel;
  logic [31:0] pwdata;
  logic pwrite;
  logic [31:0] prdata;
  logic pready;
  logic pslverr;
  logic irq;

  integer errors;
  integer acts [0:1][0:1][0:7];
  integer weights [0:1][0:31][0:7];
  integer bias [0:31];

  always #5 clk = ~clk;

  group2_topmodule dut (
    .PADDR(paddr), .PENABLE(penable), .PSEL(psel), .PWDATA(pwdata),
    .PWRITE(pwrite), .PRDATA(prdata), .PREADY(pready), .PSLVERR(pslverr),
    .clk_i(clk), .rst_ni(rst_n), .wrapper_fault_i(1'b0),
    .irq_en_i(1'b1), .pmod_gpi(16'd0), .irq_o(irq),
    .pmod_gpo(), .pmod_gpio_oe()
  );

  task automatic apb_write(
      input logic [15:0] addr,
      input logic [31:0] data,
      input logic expected_error
  );
    begin
      @(negedge clk);
      paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      while (!pready) @(negedge clk);
      if (pslverr !== expected_error) begin
        $error("APB write error mismatch addr=%h expected=%0d got=%0d", addr,
               expected_error, pslverr);
        errors = errors + 1;
      end
      @(negedge clk);
      psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = '0; pwdata = '0;
    end
  endtask

  task automatic apb_read(
      input logic [15:0] addr,
      output logic [31:0] data,
      input logic expected_error
  );
    begin
      @(negedge clk);
      paddr = addr; pwdata = '0; pwrite = 1'b0; psel = 1'b1; penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      while (!pready) @(negedge clk);
      data = prdata;
      if (pslverr !== expected_error) begin
        $error("APB read error mismatch addr=%h expected=%0d got=%0d", addr,
               expected_error, pslverr);
        errors = errors + 1;
      end
      @(negedge clk);
      psel = 1'b0; penable = 1'b0; paddr = '0;
    end
  endtask

  task automatic wait_phase(input logic [2:0] expected);
    logic [31:0] status;
    integer timeout;
    begin
      timeout = 2000;
      status = '0;
      while ((status[7:5] != expected) && (timeout > 0)) begin
        apb_read(OFF_STATUS, status, 1'b0);
        timeout = timeout - 1;
      end
      if (timeout == 0) begin
        $error("phase timeout expected=%0d status=%h", expected, status);
        errors = errors + 1;
      end
    end
  endtask

  task automatic stream_weights(input integer tile);
    logic [31:0] word;
    integer n;
    integer k;
    begin
      for (n = 0; n < 32; n = n + 1) begin
        word = '0;
        for (k = 0; k < 8; k = k + 1) begin
          word[k*4 +: 4] = weights[tile][n][k][3:0];
        end
        apb_write(OFF_WEIGHT_DATA, word, 1'b0);
      end
    end
  endtask

  task automatic stream_activations(input integer tile);
    logic [31:0] word;
    integer m;
    integer k;
    begin
      for (m = 0; m < 2; m = m + 1) begin
        for (k = 0; k < 8; k = k + 2) begin
          word[15:0]  = acts[tile][m][k][15:0];
          word[31:16] = acts[tile][m][k+1][15:0];
          apb_write(OFF_ACT_DATA, word, 1'b0);
        end
      end
    end
  endtask

  task automatic check_outputs;
    logic [31:0] word;
    logic [15:0] expected;
    integer m;
    integer n;
    integer k;
    integer total;
    integer lane;
    begin
      for (m = 0; m < 2; m = m + 1) begin
        for (n = 0; n < 32; n = n + 2) begin
          apb_read(OFF_OUTPUT_BASE + m*64 + (n/2)*4, word, 1'b0);
          for (lane = 0; lane < 2; lane = lane + 1) begin
            total = bias[n+lane];
            for (k = 0; k < 8; k = k + 1) begin
              total = total + acts[0][m][k] * weights[0][n+lane][k];
              total = total + acts[1][m][k] * weights[1][n+lane][k];
            end
            expected = total[15:0];
            if (word[lane*16 +: 16] !== expected) begin
              $error("C[%0d][%0d] expected=%h got=%h", m, n+lane,
                     expected, word[lane*16 +: 16]);
              errors = errors + 1;
            end
          end
        end
      end
    end
  endtask

  initial begin
    logic [31:0] data;
    logic [31:0] cfg;
    integer m;
    integer n;
    integer k;

    errors = 0;
    paddr = '0; penable = 1'b0; psel = 1'b0; pwdata = '0; pwrite = 1'b0;

    for (n = 0; n < 32; n = n + 1) begin
      bias[n] = n * 997 - 15000;
      for (k = 0; k < 8; k = k + 1) begin
        weights[0][n][k] = ((n + k) % 15) - 7;
        weights[1][n][k] = ((n + 2*k + 3) % 15) - 7;
      end
    end
    for (m = 0; m < 2; m = m + 1) begin
      for (k = 0; k < 8; k = k + 1) begin
        acts[0][m][k] = (m == 0) ? (30000 - k*777) : (-30000 + k*613);
        acts[1][m][k] = (m == 0) ? (-25000 + k*431) : (26000 - k*509);
      end
    end

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    apb_read(OFF_VERSION, data, 1'b0);
    if (data !== VERSION) begin
      $error("VERSION expected=%h got=%h", VERSION, data);
      errors = errors + 1;
    end

    cfg = DTYPE_INT16 | (DTYPE_INT4 << 2) | (32'd2 << 4) | (32'd1 << 10);
    apb_write(OFF_CONFIG, cfg, 1'b0);
    for (n = 0; n < 32; n = n + 2) begin
      data[15:0]  = bias[n][15:0];
      data[31:16] = bias[n+1][15:0];
      apb_write(OFF_BIAS_BASE + (n/2)*4, data, 1'b0);
    end

    apb_write(OFF_CONTROL, CTRL_START_GACC, 1'b1);
    apb_write(OFF_CONTROL, CTRL_CLEAR_ERROR, 1'b0);

    apb_write(OFF_CONTROL, CTRL_START_GEMM, 1'b0);
    wait_phase(PH_WEIGHT);
    stream_weights(0);
    wait_phase(PH_ACTIVATION);
    stream_activations(0);
    wait_phase(PH_OUTPUT);

    apb_write(OFF_CONTROL, CTRL_START_GACC, 1'b0);
    wait_phase(PH_WEIGHT);
    stream_weights(1);
    wait_phase(PH_ACTIVATION);
    stream_activations(1);
    wait_phase(PH_OUTPUT);

    apb_read(OFF_OUTPUT_WORDS, data, 1'b0);
    if (data !== 32) begin
      $error("OUTPUT_WORDS expected=32 got=%0d", data);
      errors = errors + 1;
    end
    check_outputs();

    if (!irq) begin
      $error("IRQ must remain asserted while done is sticky");
      errors = errors + 1;
    end

    apb_write(OFF_CONTROL, CTRL_RELEASE_CONTEXT, 1'b0);
    wait_phase(PH_IDLE);
    apb_read(OFF_OUTPUT_BASE, data, 1'b1);

    // Exercise the maximum row count, the last physical SRAM row, and the
    // bias-disabled path with a zero matrix.
    cfg = DTYPE_INT4 | (DTYPE_INT4 << 2) | (32'd32 << 4);
    apb_write(OFF_CONFIG, cfg, 1'b0);
    apb_write(OFF_CONTROL, CTRL_START_GEMM, 1'b0);
    wait_phase(PH_WEIGHT);
    for (n = 0; n < 32; n = n + 1) begin
      apb_write(OFF_WEIGHT_DATA, 32'd0, 1'b0);
    end
    wait_phase(PH_ACTIVATION);
    for (m = 0; m < 32; m = m + 1) begin
      apb_write(OFF_ACT_DATA, 32'd0, 1'b0);
    end
    wait_phase(PH_OUTPUT);
    apb_read(OFF_OUTPUT_WORDS, data, 1'b0);
    if (data !== 512) begin
      $error("M=32 OUTPUT_WORDS expected=512 got=%0d", data);
      errors = errors + 1;
    end
    apb_read(OFF_OUTPUT_BASE + 31*64 + 15*4, data, 1'b0);
    if (data !== 0) begin
      $error("M=32 last output expected=0 got=%h", data);
      errors = errors + 1;
    end
    apb_write(OFF_CONTROL, CTRL_RELEASE_CONTEXT, 1'b0);
    wait_phase(PH_IDLE);

    // A synchronous soft reset must abort an in-flight stream and invalidate
    // all software-visible context without requiring an async reset edge.
    apb_write(OFF_CONTROL, CTRL_START_GEMM, 1'b0);
    wait_phase(PH_WEIGHT);
    apb_write(OFF_WEIGHT_DATA, 32'd0, 1'b0);
    apb_write(OFF_CONTROL, CTRL_SOFT_RESET, 1'b0);
    wait_phase(PH_IDLE);
    apb_read(OFF_STATUS, data, 1'b0);
    if (data[4:0] !== 0) begin
      $error("soft reset left status bits set: %h", data);
      errors = errors + 1;
    end
    apb_read(OFF_CONFIG, data, 1'b0);
    if (data !== 0) begin
      $error("soft reset did not clear CONFIG: %h", data);
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("GROUP2_FINAL_TB_PASS");
    end else begin
      $fatal(1, "GROUP2_FINAL_TB_FAIL errors=%0d", errors);
    end
    $finish;
  end

endmodule
