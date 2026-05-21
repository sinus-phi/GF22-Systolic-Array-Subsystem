//-----------------------------------------------------------------------------
// File          : Student_SS_3.v
// Creation date : 23.04.2024
// Creation time : 12:45:24
// Description   : 
// Created by    : 
// Tool : Kactus2 3.13.1 64-bit
// Plugin : Verilog generator 2.4
// Interface was originally generated based on IP-XACT component tuni.fi:subsystem:Student_SS_3:1.0
//-----------------------------------------------------------------------------
/*
  Contributors:
    * Matti Käyrä (matti.kayra@tuni.fi)
  Description:
    * example student area tieoff code
*/

module Student_SS_3(
    // Interface: APB
    input  logic [31:0] PADDR,
    input  logic        PENABLE,
    input  logic        PSEL,
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
    output logic        irq_3,

    // Interface: Reset
    input  logic        reset_int,

    // Interface: SS_Ctrl
    input  logic        irq_en_3,
    input  logic [7:0]  ss_ctrl_3,
    
    //Interface: GPIO pmod 
    input  logic [15:0]  pmod_gpi,
    output logic [15:0]  pmod_gpo,
    output logic [15:0]  pmod_gpio_oe

);

// WARNING: EVERYTHING ON AND ABOVE THIS LINE MAY BE OVERWRITTEN BY KACTUS2!!!

  sa_dummy_accel i_sa_dummy_accel (
    .PADDR         (PADDR),
    .PENABLE       (PENABLE),
    .PSEL          (PSEL),
    .PWDATA        (PWDATA),
    .PWRITE        (PWRITE),
    .PRDATA        (PRDATA),
    .PREADY        (PREADY),
    .PSLVERR       (PSLVERR),
    .clk_i         (clk_in),
    .rst_ni        (reset_int),
    .irq_en_i      (irq_en_3),
    .ss_ctrl_i     (ss_ctrl_3),
    .pmod_gpi      (pmod_gpi),
    .irq_o         (irq_3),
    .pmod_gpo      (pmod_gpo),
    .pmod_gpio_oe  (pmod_gpio_oe)
  );

  wire _unused_student_ss_3 = &{1'b0, high_speed_clk, 1'b0};

endmodule
