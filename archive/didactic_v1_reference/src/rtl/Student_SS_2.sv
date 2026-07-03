//-----------------------------------------------------------------------------
// File          : student_ss_2.v
// Creation date : 22.04.2024
// Creation time : 14:06:50
// Description   : 
// Created by    : 
// Tool : Kactus2 3.13.1 64-bit
// Plugin : Verilog generator 2.4
// Interface was originally generated based on IP-XACT component tuni.fi:subsystem:student_ss_2:1.0
//-----------------------------------------------------------------------------
/*
  Contributors:
    * Matti Käyrä (matti.kayra@tuni.fi)
  Description:
    * example student area tieoff code
*/

module student_ss_2(
    // Interface: APB
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
    input  logic [3:0]  PSTRB,
    input  logic [31:0] PWDATA,
    input  logic        PWRITE,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    // Interface: Clock
    input  logic        clk_in,

    // Interface: high_speed_clock
    input  logic        high_speed_clk,

    // Interface: IRQ
    output logic        irq_2,

    // Interface: Reset
    input  logic        reset_int,

    // Interface: SS_Ctrl
    input  logic        irq_en_2,
    input  logic [7:0]  ss_ctrl_2,

    //Interface: GPIO pmod 0
    input  logic [15:0]  pmod_gpi,
    output logic [15:0]  pmod_gpo,
    output logic [15:0]  pmod_gpio_oe
);

// WARNING: EVERYTHING ON AND ABOVE THIS LINE MAY BE OVERWRITTEN BY KACTUS2!!!

  subsystem_topmodule i_subsystem_topmodule (
    .PADDR         (PADDR),
    .PENABLE       (PENABLE),
    .PSEL          (PSEL),
    .PSTRB         (PSTRB),
    .PWDATA        (PWDATA),
    .PWRITE        (PWRITE),
    .PRDATA        (PRDATA),
    .PREADY        (PREADY),
    .PSLVERR       (PSLVERR),
    .clk_i         (clk_in),
    .rst_ni        (reset_int),
    .irq_en_i      (irq_en_2),
    .ss_ctrl_i     (ss_ctrl_2),
    .pmod_gpi      (pmod_gpi),
    .irq_o         (irq_2),
    .pmod_gpo      (pmod_gpo),
    .pmod_gpio_oe  (pmod_gpio_oe)
  );

  wire _unused_student_ss_2 = &{1'b0, high_speed_clk, 1'b0};

endmodule
