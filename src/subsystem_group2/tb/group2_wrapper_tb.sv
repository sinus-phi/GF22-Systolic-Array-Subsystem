`timescale 1ns/1ps

module tc_clk_gating (
    input logic clk_i,
    input logic en_i,
    input logic test_en_i,
    output logic clk_o
);
  assign clk_o = clk_i;
  wire _unused = &{1'b0, en_i, test_en_i, 1'b0};
endmodule

module group2_wrapper_tb;
  logic clk = 1'b0;
  logic reset_n = 1'b0;
  logic [31:0] paddr;
  logic penable;
  logic psel;
  logic [3:0] pstrb;
  logic [31:0] pwdata;
  logic pwrite;
  logic [31:0] prdata;
  logic pready;
  logic pslverr;
  integer errors = 0;

  always #5 clk = ~clk;

  student_wrapper_1 dut (
    .PADDR(paddr), .PENABLE(penable), .PSEL(psel), .PSTRB(pstrb),
    .PWDATA(pwdata), .PWRITE(pwrite), .PRDATA(prdata), .PREADY(pready),
    .PSLVERR(pslverr), .clk_in(clk), .irq(), .pmod_gpi(16'd0),
    .pmod_gpio_oe(), .pmod_gpo(), .clk_en(1'b1), .irq_en(1'b1),
    .reset_n(reset_n)
  );

  task automatic write_apb(input [15:0] addr, input [31:0] data,
                           input [3:0] strb, input expected_error);
    begin
      @(negedge clk);
      paddr = addr; pwdata = data; pstrb = strb;
      pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      while (!pready) @(negedge clk);
      if (pslverr !== expected_error) begin
        $error("wrapper write error mismatch addr=%h", addr);
        errors = errors + 1;
      end
      @(negedge clk);
      psel = 1'b0; penable = 1'b0; pwrite = 1'b0; pstrb = 4'h0;
    end
  endtask

  task automatic read_apb(input [15:0] addr, output [31:0] data,
                          input expected_error);
    begin
      @(negedge clk);
      paddr = addr; pwrite = 1'b0; psel = 1'b1; penable = 1'b0;
      @(negedge clk);
      penable = 1'b1;
      while (!pready) @(negedge clk);
      data = prdata;
      if (pslverr !== expected_error) begin
        $error("wrapper read error mismatch addr=%h expected=%0d got=%0d",
               addr, expected_error, pslverr);
        errors = errors + 1;
      end
      @(negedge clk);
      psel = 1'b0; penable = 1'b0;
    end
  endtask

  initial begin
    logic [31:0] data;
    paddr = '0; penable = 1'b0; psel = 1'b0; pstrb = '0;
    pwdata = '0; pwrite = 1'b0;
    repeat (5) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);

    write_apb(16'h0008, 32'h0000_0020, 4'b0011, 1'b1);
    repeat (2) @(posedge clk);
    read_apb(16'h0008, data, 1'b0);
    if (data != 0) begin
      $error("partial CONFIG write changed state: %h", data);
      errors = errors + 1;
    end
    read_apb(16'h0004, data, 1'b0);
    if (!data[1]) begin
      $error("partial write did not set error sticky");
      errors = errors + 1;
    end

    write_apb(16'h0000, 32'h0000_0008, 4'hF, 1'b0);
    read_apb(16'h0004, data, 1'b0);
    if (data[1]) begin
      $error("CLEAR_ERROR did not clear sticky status");
      errors = errors + 1;
    end

    write_apb(16'h0008, 32'h0000_0020, 4'hF, 1'b0);
    read_apb(16'h0008, data, 1'b0);
    if (data != 32'h0000_0020) begin
      $error("full CONFIG write mismatch: %h", data);
      errors = errors + 1;
    end

    read_apb(16'h0005, data, 1'b1);
    repeat (2) @(posedge clk);
    read_apb(16'h0010, data, 1'b0);
    if (data != 32'd2) begin
      $error("unaligned access error code mismatch: %0d", data);
      errors = errors + 1;
    end
    write_apb(16'h0000, 32'h0000_0008, 4'hF, 1'b0);

    write_apb(16'h0000, 32'h0000_0000, 4'hF, 1'b1);
    repeat (2) @(posedge clk);
    read_apb(16'h0010, data, 1'b0);
    if (data != 32'd11) begin
      $error("illegal command error code mismatch: %0d", data);
      errors = errors + 1;
    end
    write_apb(16'h0000, 32'h0000_0008, 4'hF, 1'b0);

    read_apb(16'hFFFC, data, 1'b1);
    repeat (2) @(posedge clk);
    read_apb(16'h0010, data, 1'b0);
    if (data != 32'd1) begin
      $error("bad address error code mismatch: %0d", data);
      errors = errors + 1;
    end

    if (errors == 0) $display("GROUP2_WRAPPER_TB_PASS");
    else $fatal(1, "GROUP2_WRAPPER_TB_FAIL errors=%0d", errors);
    $finish;
  end
endmodule
