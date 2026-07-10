// FPGA-only student wrappers for the generated Didactic top.
// Slot 2 (student_wrapper_1) contains Group 2; all other slots are tied off.

`timescale 1ns/1ps

module group2_fpga_student_tieoff #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    input  logic        clk_in,

    output logic        irq,

    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,

    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);

  assign PRDATA       = 32'd0;
  assign PREADY       = 1'b1;
  assign PSLVERR      = 1'b0;
  assign irq          = 1'b0;
  assign pmod_gpio_oe = 16'd0;
  assign pmod_gpo     = 16'd0;

  wire _unused = &{
    1'b0,
    PADDR,
    PENABLE,
    PSEL,
    PSTRB,
    PWDATA,
    PWRITE,
    clk_in,
    pmod_gpi,
    clk_en,
    irq_en,
    reset_n,
    1'b0
  };

endmodule

module student_wrapper_0 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule

module student_wrapper_1 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);

  logic group2_clk;
  logic group2_irq;
  logic [31:0] group2_prdata;
  logic        group2_pready;
  logic        group2_pslverr;
  logic        partial_write;

  // The SoC controls the subsystem clock through clk_en.
  tc_clk_gating i_group2_clk_gate (
    .clk_i     (clk_in),
    .en_i      (clk_en),
    .test_en_i (1'b0),
    .clk_o     (group2_clk)
  );

  group2_topmodule i_group2_topmodule (
    .PADDR        (PADDR[15:0]),
    .PENABLE      (PENABLE),
    .PSEL         (PSEL && !partial_write),
    .PWDATA       (PWDATA),
    .PWRITE       (PWRITE),
    .PRDATA       (group2_prdata),
    .PREADY       (group2_pready),
    .PSLVERR      (group2_pslverr),
    .clk_i        (group2_clk),
    .rst_ni       (reset_n),
    .wrapper_fault_i (partial_write && PENABLE),
    .irq_en_i     (irq_en),
    .pmod_gpi     (pmod_gpi),
    .irq_o        (group2_irq),
    .pmod_gpo     (pmod_gpo),
    .pmod_gpio_oe (pmod_gpio_oe)
  );

  // Group 2 accepts full 32-bit writes; reject partial PSTRB at the wrapper.
  assign partial_write = PSEL && PWRITE && (PSTRB != 4'b1111);
  assign PRDATA  = partial_write ? 32'd0 : group2_prdata;
  assign PREADY  = partial_write ? 1'b1 : group2_pready;
  assign PSLVERR = partial_write ? 1'b1 : group2_pslverr;
  assign irq     = group2_irq & irq_en;

  wire _unused = &{1'b0, PADDR[31:16], 1'b0};

endmodule

module student_wrapper_2 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule

module student_wrapper_3 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule

module student_wrapper_4 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule

module student_wrapper_5 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule

module student_wrapper_6 #(
    parameter APB_DW = 32,
    parameter APB_AW = 32,
    parameter NUM_GPIO = 16
) (
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    input  logic        clk_in,
    output logic        irq,
    input  logic [15:0] pmod_gpi,
    output logic [15:0] pmod_gpio_oe,
    output logic [15:0] pmod_gpo,
    input  logic        clk_en,
    input  logic        irq_en,
    input  logic        reset_n
);
  group2_fpga_student_tieoff #(
    .APB_DW(APB_DW),
    .APB_AW(APB_AW),
    .NUM_GPIO(NUM_GPIO)
  ) i_tieoff (.*);
endmodule
