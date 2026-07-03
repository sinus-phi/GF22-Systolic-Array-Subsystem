`timescale 1ns/1ps

// Standalone APB-level testbench for the compact 5-state SA dummy shell.
// It verifies firmware-visible sequencing without instantiating the full SoC.
module tb_sa_dummy_accel;

  localparam logic [31:0] OFF_CONTROL      = 32'h0000_0000;
  localparam logic [31:0] OFF_STATUS       = 32'h0000_0004;
  localparam logic [31:0] OFF_CONFIG       = 32'h0000_0008;
  localparam logic [31:0] OFF_PROGRESS     = 32'h0000_000C;
  localparam logic [31:0] OFF_ERROR_CODE   = 32'h0000_0010;
  localparam logic [31:0] OFF_OUTPUT_WORDS = 32'h0000_0014;
  localparam logic [31:0] WEIGHT_BASE      = 32'h0000_0100;
  localparam logic [31:0] ACT_BASE         = 32'h0000_0200;
  localparam logic [31:0] OUTPUT_BASE      = 32'h0000_0400;

  localparam logic [2:0] PH_IDLE            = 3'd0;
  localparam logic [2:0] PH_LOAD_WEIGHTS    = 3'd1;
  localparam logic [2:0] PH_BATCH_COMPUTE   = 3'd2;
  localparam logic [2:0] PH_DRAIN_WRITEBACK = 3'd3;
  localparam logic [2:0] PH_ERROR           = 3'd4;

  localparam logic [31:0] CTRL_LOAD_WEIGHTS   = 32'h0000_0001;
  localparam logic [31:0] CTRL_RELEASE_OUTPUT = 32'h0000_0002;
  localparam logic [31:0] CTRL_CLEAR_DONE     = 32'h0000_0004;
  localparam logic [31:0] CTRL_CLEAR_ERROR    = 32'h0000_0008;
  localparam logic [31:0] CTRL_SOFT_RESET     = 32'h0000_0010;

  localparam logic [31:0] ERR_NONE           = 32'd0;
  localparam logic [31:0] ERR_BAD_ADDR       = 32'd1;
  localparam logic [31:0] ERR_UNALIGNED      = 32'd2;
  localparam logic [31:0] ERR_BAD_STATE      = 32'd3;
  localparam logic [31:0] ERR_OUTPUT_RANGE   = 32'd4;
  localparam logic [31:0] ERR_INVALID_CONFIG = 32'd5;

  localparam logic [1:0] PROG_NONE       = 2'd0;
  localparam logic [1:0] PROG_WEIGHT     = 2'd1;
  localparam logic [1:0] PROG_ACTIVATION = 2'd2;
  localparam logic [1:0] PROG_DRAIN      = 2'd3;

  logic        clk;
  logic        rst_n;
  logic        irq_en;
  logic [31:0] paddr;
  logic        penable;
  logic        psel;
  logic [31:0] pwdata;
  logic        pwrite;
  logic [31:0] prdata;
  logic        pready;
  logic        pslverr;
  logic        irq;
  logic [15:0] pmod_gpi;
  logic [15:0] pmod_gpo;
  logic [15:0] pmod_gpio_oe;

  int unsigned errors;

  sa_dummy_accel dut (
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
    .irq_en_i     (irq_en),
    .ss_ctrl_i    (8'h01),
    .pmod_gpi     (pmod_gpi),
    .irq_o        (irq),
    .pmod_gpo     (pmod_gpo),
    .pmod_gpio_oe (pmod_gpio_oe)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic fail(input string msg);
    begin
      errors++;
      $error("[FAIL] %s", msg);
    end
  endtask

  task automatic expect_eq(
      input string       name,
      input logic [31:0] got,
      input logic [31:0] exp
  );
    begin
      if (got !== exp) begin
        errors++;
        $error("[FAIL] %s got=0x%08h exp=0x%08h", name, got, exp);
      end else begin
        $display("[ OK ] %s = 0x%08h", name, got);
      end
    end
  endtask

  task automatic apb_write(
      input logic [31:0] addr,
      input logic [31:0] data,
      input bit          exp_err
  );
    begin
      @(negedge clk);
      paddr   = addr;
      pwdata  = data;
      pwrite  = 1'b1;
      psel    = 1'b1;
      penable = 1'b0;

      @(negedge clk);
      penable = 1'b1;

      #1;
      if (!pready) begin
        fail("APB write did not assert PREADY");
      end
      if (pslverr !== exp_err) begin
        errors++;
        $error("[FAIL] APB write addr=0x%08h data=0x%08h PSLVERR=%0b exp=%0b",
               addr, data, pslverr, exp_err);
      end

      @(posedge clk);
      @(negedge clk);
      psel    = 1'b0;
      penable = 1'b0;
      pwrite  = 1'b0;
      paddr   = 32'd0;
      pwdata  = 32'd0;
    end
  endtask

  task automatic apb_read(
      input  logic [31:0] addr,
      output logic [31:0] data,
      input  bit          exp_err
  );
    begin
      @(negedge clk);
      paddr   = addr;
      pwdata  = 32'd0;
      pwrite  = 1'b0;
      psel    = 1'b1;
      penable = 1'b0;

      @(negedge clk);
      penable = 1'b1;

      #1;
      data = prdata;
      if (!pready) begin
        fail("APB read did not assert PREADY");
      end
      if (pslverr !== exp_err) begin
        errors++;
        $error("[FAIL] APB read addr=0x%08h PSLVERR=%0b exp=%0b",
               addr, pslverr, exp_err);
      end

      @(posedge clk);
      @(negedge clk);
      psel    = 1'b0;
      penable = 1'b0;
      paddr   = 32'd0;
    end
  endtask

  function automatic logic [2:0] phase_of(input logic [31:0] status);
    phase_of = status[9:7];
  endfunction

  function automatic logic busy_of(input logic [31:0] status);
    busy_of = status[0];
  endfunction

  function automatic logic done_sticky_of(input logic [31:0] status);
    done_sticky_of = status[2];
  endfunction

  function automatic logic error_sticky_of(input logic [31:0] status);
    error_sticky_of = status[1];
  endfunction

  function automatic logic weights_valid_of(input logic [31:0] status);
    weights_valid_of = status[3];
  endfunction

  function automatic logic output_valid_of(input logic [31:0] status);
    output_valid_of = status[4];
  endfunction

  function automatic logic output_full_of(input logic [31:0] status);
    output_full_of = status[5];
  endfunction

  function automatic logic output_blocked_of(input logic [31:0] status);
    output_blocked_of = status[6];
  endfunction

  function automatic logic [31:0] status_error_code_of(input logic [31:0] status);
    status_error_code_of = {28'd0, status[13:10]};
  endfunction

  function automatic logic [31:0] output_valid_count_of(input logic [31:0] status);
    output_valid_count_of = {30'd0, status[15:14]};
  endfunction

  function automatic logic [31:0] output_words_of(input logic [31:0] status);
    output_words_of = {25'd0, status[22:16]};
  endfunction

  function automatic logic [31:0] progress_current_of(input logic [31:0] progress);
    progress_current_of = {23'd0, progress[8:0]};
  endfunction

  function automatic logic [31:0] progress_target_of(input logic [31:0] progress);
    progress_target_of = {23'd0, progress[17:9]};
  endfunction

  function automatic logic [31:0] progress_batch_remaining_of(input logic [31:0] progress);
    progress_batch_remaining_of = {27'd0, progress[22:18]};
  endfunction

  function automatic logic [1:0] progress_kind_of(input logic [31:0] progress);
    progress_kind_of = progress[24:23];
  endfunction

  // Poll STATUS until the requested phase appears. Any timeout is reported as
  // a test failure instead of silently hanging the simulation.
  task automatic wait_phase(input logic [2:0] exp_phase);
    logic [31:0] status;
    int unsigned timeout;
    begin
      timeout = 0;
      do begin
        apb_read(OFF_STATUS, status, 1'b0);
        timeout++;
        if (timeout > 64) begin
          fail("Timed out waiting for phase");
          return;
        end
      end while (phase_of(status) != exp_phase);
    end
  endtask

  // The compact model has no DONE phase, so tests wait for output_valid.
  task automatic wait_output_valid;
    logic [31:0] status;
    int unsigned timeout;
    begin
      timeout = 0;
      do begin
        apb_read(OFF_STATUS, status, 1'b0);
        timeout++;
        if (timeout > 64) begin
          fail("Timed out waiting for output valid");
          return;
        end
      end while (!output_valid_of(status));
    end
  endtask

  task automatic expect_progress(
      input string       name,
      input logic [31:0] exp_current,
      input logic [31:0] exp_target,
      input logic [31:0] exp_batch_remaining,
      input logic [1:0]  exp_kind
  );
    logic [31:0] progress;
    begin
      apb_read(OFF_PROGRESS, progress, 1'b0);
      expect_eq($sformatf("%s progress.current", name),
                progress_current_of(progress), exp_current);
      expect_eq($sformatf("%s progress.target", name),
                progress_target_of(progress), exp_target);
      expect_eq($sformatf("%s progress.batch_remaining", name),
                progress_batch_remaining_of(progress), exp_batch_remaining);
      expect_eq($sformatf("%s progress.kind", name),
                {30'd0, progress_kind_of(progress)}, {30'd0, exp_kind});
    end
  endtask

  task automatic expect_error(
      input string       name,
      input logic [31:0] exp_code
  );
    logic [31:0] status;
    logic [31:0] err_code;
    begin
      wait_phase(PH_ERROR);
      apb_read(OFF_STATUS, status, 1'b0);
      apb_read(OFF_ERROR_CODE, err_code, 1'b0);
      expect_eq($sformatf("%s error_sticky", name),
                {31'd0, error_sticky_of(status)}, 32'd1);
      expect_eq($sformatf("%s STATUS.error_code", name),
                status_error_code_of(status), exp_code[3:0]);
      expect_eq($sformatf("%s ERROR_CODE", name), err_code, exp_code);
    end
  endtask

  task automatic clear_error_and_expect_idle;
    logic [31:0] status;
    logic [31:0] err_code;
    begin
      apb_write(OFF_CONTROL, CTRL_CLEAR_ERROR, 1'b0);
      wait_phase(PH_IDLE);
      apb_read(OFF_STATUS, status, 1'b0);
      apb_read(OFF_ERROR_CODE, err_code, 1'b0);
      expect_eq("clear_error error_sticky", {31'd0, error_sticky_of(status)}, 32'd0);
      expect_eq("clear_error code", err_code, ERR_NONE);
    end
  endtask

  task automatic soft_reset_and_expect_idle;
    logic [31:0] data;
    begin
      apb_write(OFF_CONTROL, CTRL_SOFT_RESET, 1'b0);
      wait_phase(PH_IDLE);
      apb_read(OFF_STATUS, data, 1'b0);
      expect_eq("soft_reset busy", {31'd0, busy_of(data)}, 32'd0);
      expect_eq("soft_reset error", {31'd0, error_sticky_of(data)}, 32'd0);
      expect_eq("soft_reset done", {31'd0, done_sticky_of(data)}, 32'd0);
      expect_eq("soft_reset weights_valid", {31'd0, weights_valid_of(data)}, 32'd0);
      expect_eq("soft_reset output_valid", {31'd0, output_valid_of(data)}, 32'd0);
      apb_read(OFF_CONFIG, data, 1'b0);
      expect_eq("soft_reset config", data, 32'd0);
    end
  endtask

  task automatic write_config_and_check(input logic [31:0] cfg);
    logic [31:0] data;
    begin
      apb_write(OFF_CONFIG, cfg, 1'b0);
      apb_read(OFF_CONFIG, data, 1'b0);
      expect_eq("CONFIG readback", data, cfg);
    end
  endtask

  task automatic push_weight_words(input int unsigned count, input logic [31:0] base_data);
    begin
      for (int unsigned idx = 0; idx < count; idx++) begin
        apb_write(WEIGHT_BASE + idx * 4, base_data + idx, 1'b0);
      end
    end
  endtask

  task automatic push_act_words(input int unsigned count, input logic [31:0] base_data);
    begin
      for (int unsigned idx = 0; idx < count; idx++) begin
        apb_write(ACT_BASE + idx * 4, base_data + idx, 1'b0);
      end
    end
  endtask

  task automatic run_config_count_case(
      input string       name,
      input logic [31:0] cfg,
      input int unsigned exp_weight_words,
      input int unsigned exp_act_words,
      input int unsigned exp_output_words
  );
    logic [31:0] data;
    begin
      $display("---- %s", name);
      soft_reset_and_expect_idle();
      write_config_and_check(cfg);
      apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
      wait_phase(PH_LOAD_WEIGHTS);
      expect_progress(name, 32'd0, exp_weight_words, cfg[24:19], PROG_WEIGHT);
      push_weight_words(exp_weight_words, 32'h9000_0000);
      wait_phase(PH_BATCH_COMPUTE);
      expect_progress(name, 32'd0, exp_act_words, cfg[24:19], PROG_ACTIVATION);
      push_act_words(exp_act_words, 32'hA000_0000);
      wait_output_valid();
      apb_read(OFF_STATUS, data, 1'b0);
      expect_eq($sformatf("%s output_words in STATUS", name),
                output_words_of(data), exp_output_words);
      apb_read(OFF_OUTPUT_WORDS, data, 1'b0);
      expect_eq($sformatf("%s OUTPUT_WORDS", name), data, exp_output_words);
      if (exp_output_words > 0) begin
        apb_read(OUTPUT_BASE, data, 1'b0);
        expect_eq($sformatf("%s OUTPUT[0]", name),
                  data, 32'hA500_0000 | cfg[7:0]);
        apb_read(OUTPUT_BASE + (exp_output_words - 1) * 4, data, 1'b0);
        expect_eq($sformatf("%s OUTPUT[last]", name),
                  data, 32'hA500_0000 | ((exp_output_words - 1) << 8) | cfg[7:0]);
      end
      apb_write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE, 1'b0);
    end
  endtask

  initial begin
    logic [31:0] data;
    logic [31:0] cfg_word;
    logic [31:0] expected;

    errors = 0;
    rst_n = 1'b0;
    irq_en = 1'b1;
    paddr = 32'd0;
    penable = 1'b0;
    psel = 1'b0;
    pwdata = 32'd0;
    pwrite = 1'b0;
    pmod_gpi = 16'h1234;

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // act INT8, weight INT8, tile_m=2, tile_n=3, tile_k=4, batch_count=2
    cfg_word = 32'h0011_0625;

    $display("===========================================");
    $display("Test 1: reset and compact config readback");
    $display("===========================================");
    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("reset phase", {29'd0, phase_of(data)}, {29'd0, PH_IDLE});
    expect_eq("reset busy", {31'd0, busy_of(data)}, 32'd0);
    expect_eq("reset done", {31'd0, done_sticky_of(data)}, 32'd0);
    expect_eq("reset error", {31'd0, error_sticky_of(data)}, 32'd0);
    expect_eq("reset weights_valid", {31'd0, weights_valid_of(data)}, 32'd0);
    expect_eq("reset output_valid", {31'd0, output_valid_of(data)}, 32'd0);
    apb_read(OFF_CONTROL, data, 1'b0);
    expect_eq("CONTROL read is zero", data, 32'd0);
    apb_read(OFF_PROGRESS, data, 1'b0);
    expect_eq("reset PROGRESS", data, 32'd0);
    apb_read(OFF_OUTPUT_WORDS, data, 1'b0);
    expect_eq("reset OUTPUT_WORDS", data, 32'd0);
    expect_eq("PMOD output tied off", {16'd0, pmod_gpo}, 32'd0);
    expect_eq("PMOD output enable tied off", {16'd0, pmod_gpio_oe}, 32'd0);
    if (irq) begin
      fail("IRQ asserted after reset");
    end
    write_config_and_check(cfg_word);

    $display("===========================================");
    $display("Test 2: 5-state normal flow with two batches");
    $display("===========================================");
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
    wait_phase(PH_LOAD_WEIGHTS);
    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("LOAD_WEIGHTS busy", {31'd0, busy_of(data)}, 32'd1);
    expect_progress("load start", 32'd0, 32'd3, 32'd2, PROG_WEIGHT);

    apb_write(WEIGHT_BASE, 32'h1111_0000, 1'b0);
    expect_progress("after weight[0]", 32'd1, 32'd3, 32'd2, PROG_WEIGHT);
    apb_write(WEIGHT_BASE, 32'h1111_0001, 1'b0);
    expect_progress("after weight[1]", 32'd2, 32'd3, 32'd2, PROG_WEIGHT);
    apb_write(WEIGHT_BASE, 32'h1111_0002, 1'b0);
    wait_phase(PH_BATCH_COMPUTE);
    expect_progress("batch0 start", 32'd0, 32'd2, 32'd2, PROG_ACTIVATION);

    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("weights_valid", {31'd0, weights_valid_of(data)}, 32'd1);

    apb_write(ACT_BASE, 32'h2222_0000, 1'b0);
    expect_progress("after act[0]", 32'd1, 32'd2, 32'd2, PROG_ACTIVATION);
    apb_write(ACT_BASE, 32'h2222_0001, 1'b0);
    wait_output_valid();

    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("done_sticky after batch0", {31'd0, done_sticky_of(data)}, 32'd1);
    expect_eq("output_valid after batch0", {31'd0, output_valid_of(data)}, 32'd1);
    expect_eq("output_full after batch0", {31'd0, output_full_of(data)}, 32'd1);
    expect_eq("output_valid_count after batch0", output_valid_count_of(data), 32'd1);
    expect_eq("output_words in STATUS", output_words_of(data), 32'd6);
    expect_eq("phase loops to BATCH_COMPUTE", {29'd0, phase_of(data)}, {29'd0, PH_BATCH_COMPUTE});
    if (!irq) begin
      fail("IRQ was not asserted by done sticky");
    end

    for (int unsigned idx = 0; idx < 6; idx++) begin
      apb_read(OUTPUT_BASE + idx * 4, data, 1'b0);
      expected = 32'hA500_0000 | (idx << 8) | cfg_word[7:0];
      expect_eq($sformatf("OUTPUT batch0[%0d]", idx), data, expected);
    end
    apb_write(OFF_CONTROL, CTRL_RELEASE_OUTPUT, 1'b0);
    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("release clears output_valid", {31'd0, output_valid_of(data)}, 32'd0);
    expect_eq("release keeps done_sticky", {31'd0, done_sticky_of(data)}, 32'd1);

    apb_write(ACT_BASE, 32'h3333_0000, 1'b0);
    apb_write(ACT_BASE, 32'h3333_0001, 1'b0);
    wait_output_valid();
    wait_phase(PH_IDLE);
    apb_read(OFF_OUTPUT_WORDS, data, 1'b0);
    expect_eq("OUTPUT_WORDS batch1", data, 32'd6);
    apb_write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE, 1'b0);
    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("done sticky clear", {31'd0, done_sticky_of(data)}, 32'd0);
    if (irq) begin
      fail("IRQ stayed asserted after done clear");
    end
    apb_write(OFF_CONFIG, 32'h0008_4215, 1'b1);
    expect_error("CONFIG locked after weight context", ERR_BAD_STATE);
    clear_error_and_expect_idle();

    $display("===========================================");
    $display("Test 3: single-slot output blocks auto-loop until release");
    $display("===========================================");
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
    wait_phase(PH_LOAD_WEIGHTS);
    apb_write(WEIGHT_BASE, 32'h4444_0000, 1'b0);
    apb_write(WEIGHT_BASE, 32'h4444_0001, 1'b0);
    apb_write(WEIGHT_BASE, 32'h4444_0002, 1'b0);
    wait_phase(PH_BATCH_COMPUTE);
    apb_write(ACT_BASE, 32'h5555_0000, 1'b0);
    apb_write(ACT_BASE, 32'h5555_0001, 1'b0);
    wait_output_valid();
    apb_write(ACT_BASE, 32'h6666_0000, 1'b0);
    apb_write(ACT_BASE, 32'h6666_0001, 1'b0);
    wait_phase(PH_DRAIN_WRITEBACK);
    apb_read(OFF_STATUS, data, 1'b0);
    expect_eq("output_blocked before release", {31'd0, output_blocked_of(data)}, 32'd1);
    apb_write(OFF_CONTROL, CTRL_RELEASE_OUTPUT, 1'b0);
    wait_output_valid();
    wait_phase(PH_IDLE);
    apb_write(OFF_CONTROL, CTRL_RELEASE_OUTPUT | CTRL_CLEAR_DONE, 1'b0);

    $display("===========================================");
    $display("Test 4: output read range error");
    $display("===========================================");
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
    wait_phase(PH_LOAD_WEIGHTS);
    apb_write(WEIGHT_BASE, 32'h7777_0000, 1'b0);
    apb_write(WEIGHT_BASE, 32'h7777_0001, 1'b0);
    apb_write(WEIGHT_BASE, 32'h7777_0002, 1'b0);
    wait_phase(PH_BATCH_COMPUTE);
    apb_write(ACT_BASE, 32'h8888_0000, 1'b0);
    apb_write(ACT_BASE, 32'h8888_0001, 1'b0);
    wait_output_valid();
    apb_read(OUTPUT_BASE + 6 * 4, data, 1'b1);
    wait_phase(PH_ERROR);
    apb_read(OFF_ERROR_CODE, data, 1'b0);
    expect_eq("ERROR_CODE output range", data, 32'd4);
    apb_write(OFF_CONTROL, CTRL_SOFT_RESET, 1'b0);
    wait_phase(PH_IDLE);

    $display("===========================================");
    $display("Test 5: wrong input window and invalid config");
    $display("===========================================");
    apb_write(ACT_BASE, 32'h6666_0000, 1'b1);
    expect_error("activation write in IDLE", ERR_BAD_STATE);
    soft_reset_and_expect_idle();

    apb_write(OFF_CONFIG, 32'd0, 1'b0);
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b1);
    expect_error("invalid zero config", ERR_INVALID_CONFIG);

    $display("===========================================");
    $display("Test 6: APB access policy and error recovery");
    $display("===========================================");
    soft_reset_and_expect_idle();
    write_config_and_check(cfg_word);

    irq_en = 1'b0;
    apb_read(OUTPUT_BASE, data, 1'b1);
    expect_error("output read before valid", ERR_BAD_STATE);
    if (irq) begin
      fail("IRQ asserted while irq_en_i is low");
    end
    irq_en = 1'b1;
    clear_error_and_expect_idle();

    apb_read(OFF_STATUS + 32'd1, data, 1'b1);
    expect_error("unaligned read", ERR_UNALIGNED);
    clear_error_and_expect_idle();

    apb_read(32'h0000_0300, data, 1'b1);
    expect_error("reserved address read", ERR_BAD_ADDR);
    clear_error_and_expect_idle();

    apb_write(WEIGHT_BASE, 32'hAAAA_0000, 1'b1);
    expect_error("weight write in IDLE", ERR_BAD_STATE);
    clear_error_and_expect_idle();

    apb_write(OUTPUT_BASE, 32'hBBBB_0000, 1'b1);
    expect_error("output window write", ERR_BAD_ADDR);
    clear_error_and_expect_idle();

    $display("===========================================");
    $display("Test 7: active-state command/config protection");
    $display("===========================================");
    soft_reset_and_expect_idle();
    write_config_and_check(cfg_word);
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
    wait_phase(PH_LOAD_WEIGHTS);
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b1);
    expect_error("load_weights while active", ERR_BAD_STATE);
    soft_reset_and_expect_idle();

    write_config_and_check(cfg_word);
    apb_write(OFF_CONTROL, CTRL_LOAD_WEIGHTS, 1'b0);
    wait_phase(PH_LOAD_WEIGHTS);
    apb_write(OFF_CONFIG, 32'h0008_4215, 1'b1);
    expect_error("CONFIG write while active", ERR_BAD_STATE);

    $display("===========================================");
    $display("Test 8: precision/count decoding cases");
    $display("===========================================");
    run_config_count_case(
        "INT4 compact 1x1x8 batch1",
        32'h000A_0210,
        1,
        1,
        1
    );
    run_config_count_case(
        "INT16 activation, INT32 weight 2x2x3 batch1",
        32'h0008_C42E,
        6,
        3,
        4
    );
    run_config_count_case(
        "INT4 max 8x8x8 output tile batch1",
        32'h000A_1080,
        8,
        8,
        64
    );

    if (errors == 0) begin
      $display("===========================================");
      $display("ALL SA DUMMY 5-STATE TESTS PASSED");
      $display("===========================================");
    end else begin
      $display("===========================================");
      $display("SA DUMMY 5-STATE TESTS FAILED: %0d error(s)", errors);
      $display("===========================================");
    end
    $finish;
  end

endmodule
