//-----------------------------------------------------------------------------
// File          : ss2_wrapper_0.v
// Creation date : 14.10.2025
// Creation time : 14:04:08
// Description   : 
// Created by    : 
// Tool : Kactus2 3.13.5 64-bit
// Plugin : Verilog generator 2.4
// This file was generated based on IP-XACT component tuni.fi:subsystem.wrapper:ss2_wrapper:1.0
// whose XML file is C:/Users/kayra/Documents/repos/Didactic-SoC/ipxact/tuni.fi/subsystem.wrapper/ss2_wrapper/1.0/ss2_wrapper.1.0.xml
//-----------------------------------------------------------------------------

module ss2_wrapper_0 #(
    parameter                              APB_AW           = 32,
    parameter                              APB_DW           = 32
) (
    // Interface: APB
    input  logic         [31:0]         PADDR,
    input  logic                        PENABLE,
    input  logic                        PSEL,
    input  logic         [3:0]          PSTRB,
    input  logic         [31:0]         PWDATA,
    input  logic                        PWRITE,
    output logic         [31:0]         PRDATA,
    output logic                        PREADY,
    output logic                        PSLVERR,

    // Interface: Clock
    input  logic                        clk,

    // Interface: IRQ
    output logic                        irq,

    // Interface: Reset
    input  logic                        reset_int,

    // Interface: SS_Ctrl
    input  logic                        irq_en_2,
    input  logic         [7:0]          ss_ctrl_2,

    // Interface: high_speed_clk
    input  logic                        high_speed_clk,

    // Interface: pmod_gpio
    input  logic         [15:0]         pmod_gpi,
    output logic         [15:0]         pmod_gpio_oe,
    output logic         [15:0]         pmod_gpo
);

    // ss_cg_clk_in_to_Clock wires:
    wire       ss_cg_clk_in_to_Clock_clk;
    // ss_cg_clk_out_to_i_student_ss2_Clock wires:
    wire       ss_cg_clk_out_to_i_student_ss2_Clock_clk;
    // i_student_ss2_Reset_to_Reset wires:
    wire       i_student_ss2_Reset_to_Reset_reset;
    // i_student_ss2_SS_Ctrl_to_SS_Ctrl wires:
    wire [7:0] i_student_ss2_SS_Ctrl_to_SS_Ctrl_clk_ctrl;
    wire       i_student_ss2_SS_Ctrl_to_SS_Ctrl_irq_en;
    // i_student_ss2_APB_to_APB wires:
    wire [31:0] i_student_ss2_APB_to_APB_PADDR;
    wire       i_student_ss2_APB_to_APB_PENABLE;
    wire [31:0] i_student_ss2_APB_to_APB_PRDATA;
    wire       i_student_ss2_APB_to_APB_PREADY;
    wire       i_student_ss2_APB_to_APB_PSEL;
    wire       i_student_ss2_APB_to_APB_PSLVERR;
    wire [3:0] i_student_ss2_APB_to_APB_PSTRB;
    wire [31:0] i_student_ss2_APB_to_APB_PWDATA;
    wire       i_student_ss2_APB_to_APB_PWRITE;
    // i_student_ss2_IRQ_to_IRQ wires:
    wire       i_student_ss2_IRQ_to_IRQ_irq;
    // i_student_ss2_high_speed_clock_to_ss_high_speed_cg_clk_out wires:
    wire       i_student_ss2_high_speed_clock_to_ss_high_speed_cg_clk_out_clk;
    // ss_high_speed_cg_clk_in_to_high_speed_clk wires:
    wire       ss_high_speed_cg_clk_in_to_high_speed_clk_clk;
    // i_student_ss2_pmod_gpio_to_pmod_gpio wires:
    wire [15:0] i_student_ss2_pmod_gpio_to_pmod_gpio_gpi;
    wire [15:0] i_student_ss2_pmod_gpio_to_pmod_gpio_gpio_oe;
    wire [15:0] i_student_ss2_pmod_gpio_to_pmod_gpio_gpo;

    // Ad-hoc wires:
    wire       ss_cg_en_to_ss_ctrl_2;
    wire       ss_high_speed_cg_en_to_ss_ctrl_2;

    // i_student_ss2 port wires:
    wire [31:0] i_student_ss2_PADDR;
    wire       i_student_ss2_PENABLE;
    wire [31:0] i_student_ss2_PRDATA;
    wire       i_student_ss2_PREADY;
    wire       i_student_ss2_PSEL;
    wire       i_student_ss2_PSLVERR;
    wire [3:0] i_student_ss2_PSTRB;
    wire [31:0] i_student_ss2_PWDATA;
    wire       i_student_ss2_PWRITE;
    wire       i_student_ss2_clk_in;
    wire       i_student_ss2_high_speed_clk;
    wire       i_student_ss2_irq_2;
    wire       i_student_ss2_irq_en_2;
    wire [15:0] i_student_ss2_pmod_gpi;
    wire [15:0] i_student_ss2_pmod_gpio_oe;
    wire [15:0] i_student_ss2_pmod_gpo;
    wire       i_student_ss2_reset_int;
    wire [7:0] i_student_ss2_ss_ctrl_2;
    // ss_cg port wires:
    wire       ss_cg_clk;
    wire       ss_cg_clk_out;
    wire       ss_cg_en;
    // ss_high_speed_cg port wires:
    wire       ss_high_speed_cg_clk;
    wire       ss_high_speed_cg_clk_out;
    wire       ss_high_speed_cg_en;

    // Assignments for the ports of the encompassing component:
    assign i_student_ss2_APB_to_APB_PADDR = PADDR;
    assign i_student_ss2_APB_to_APB_PENABLE = PENABLE;
    assign PRDATA = i_student_ss2_APB_to_APB_PRDATA;
    assign PREADY = i_student_ss2_APB_to_APB_PREADY;
    assign i_student_ss2_APB_to_APB_PSEL = PSEL;
    assign PSLVERR = i_student_ss2_APB_to_APB_PSLVERR;
    assign i_student_ss2_APB_to_APB_PSTRB = PSTRB;
    assign i_student_ss2_APB_to_APB_PWDATA = PWDATA;
    assign i_student_ss2_APB_to_APB_PWRITE = PWRITE;
    assign ss_cg_clk_in_to_Clock_clk = clk;
    assign ss_high_speed_cg_clk_in_to_high_speed_clk_clk = high_speed_clk;
    assign irq = i_student_ss2_IRQ_to_IRQ_irq;
    assign i_student_ss2_SS_Ctrl_to_SS_Ctrl_irq_en = irq_en_2;
    assign i_student_ss2_pmod_gpio_to_pmod_gpio_gpi = pmod_gpi;
    assign pmod_gpio_oe = i_student_ss2_pmod_gpio_to_pmod_gpio_gpio_oe;
    assign pmod_gpo = i_student_ss2_pmod_gpio_to_pmod_gpio_gpo;
    assign i_student_ss2_Reset_to_Reset_reset = reset_int;
    assign i_student_ss2_SS_Ctrl_to_SS_Ctrl_clk_ctrl = ss_ctrl_2;
    assign ss_cg_en_to_ss_ctrl_2 = ss_ctrl_2[0];
    assign ss_high_speed_cg_en_to_ss_ctrl_2 = ss_ctrl_2[1];

    // i_student_ss2 assignments:
    assign i_student_ss2_PADDR = i_student_ss2_APB_to_APB_PADDR;
    assign i_student_ss2_PENABLE = i_student_ss2_APB_to_APB_PENABLE;
    assign i_student_ss2_APB_to_APB_PRDATA = i_student_ss2_PRDATA;
    assign i_student_ss2_APB_to_APB_PREADY = i_student_ss2_PREADY;
    assign i_student_ss2_PSEL = i_student_ss2_APB_to_APB_PSEL;
    assign i_student_ss2_APB_to_APB_PSLVERR = i_student_ss2_PSLVERR;
    assign i_student_ss2_PSTRB = i_student_ss2_APB_to_APB_PSTRB;
    assign i_student_ss2_PWDATA = i_student_ss2_APB_to_APB_PWDATA;
    assign i_student_ss2_PWRITE = i_student_ss2_APB_to_APB_PWRITE;
    assign i_student_ss2_clk_in = ss_cg_clk_out_to_i_student_ss2_Clock_clk;
    assign i_student_ss2_high_speed_clk = i_student_ss2_high_speed_clock_to_ss_high_speed_cg_clk_out_clk;
    assign i_student_ss2_IRQ_to_IRQ_irq = i_student_ss2_irq_2;
    assign i_student_ss2_irq_en_2 = i_student_ss2_SS_Ctrl_to_SS_Ctrl_irq_en;
    assign i_student_ss2_pmod_gpi = i_student_ss2_pmod_gpio_to_pmod_gpio_gpi;
    assign i_student_ss2_pmod_gpio_to_pmod_gpio_gpio_oe = i_student_ss2_pmod_gpio_oe;
    assign i_student_ss2_pmod_gpio_to_pmod_gpio_gpo = i_student_ss2_pmod_gpo;
    assign i_student_ss2_reset_int = i_student_ss2_Reset_to_Reset_reset;
    assign i_student_ss2_ss_ctrl_2 = i_student_ss2_SS_Ctrl_to_SS_Ctrl_clk_ctrl;
    // ss_cg assignments:
    assign ss_cg_clk = ss_cg_clk_in_to_Clock_clk;
    assign ss_cg_clk_out_to_i_student_ss2_Clock_clk = ss_cg_clk_out;
    assign ss_cg_en = ss_cg_en_to_ss_ctrl_2;
    // ss_high_speed_cg assignments:
    assign ss_high_speed_cg_clk = ss_high_speed_cg_clk_in_to_high_speed_clk_clk;
    assign i_student_ss2_high_speed_clock_to_ss_high_speed_cg_clk_out_clk = ss_high_speed_cg_clk_out;
    assign ss_high_speed_cg_en = ss_high_speed_cg_en_to_ss_ctrl_2;

    // Local SS2 integration patch: keep the generated SS2 wrapper and clock
    // gates, but route the slot to the project subsystem leaf.
    student_ss_2 i_student_ss2(
        // Interface: APB
        .PADDR               (i_student_ss2_PADDR),
        .PENABLE             (i_student_ss2_PENABLE),
        .PSEL                (i_student_ss2_PSEL),
        .PSTRB               (i_student_ss2_PSTRB),
        .PWDATA              (i_student_ss2_PWDATA),
        .PWRITE              (i_student_ss2_PWRITE),
        .PRDATA              (i_student_ss2_PRDATA),
        .PREADY              (i_student_ss2_PREADY),
        .PSLVERR             (i_student_ss2_PSLVERR),
        // Interface: Clock
        .clk_in              (i_student_ss2_clk_in),
        // Interface: IRQ
        .irq_2               (i_student_ss2_irq_2),
        // Interface: Reset
        .reset_int           (i_student_ss2_reset_int),
        // Interface: SS_Ctrl
        .irq_en_2            (i_student_ss2_irq_en_2),
        .ss_ctrl_2           (i_student_ss2_ss_ctrl_2),
        // Interface: high_speed_clock
        .high_speed_clk      (i_student_ss2_high_speed_clk),
        // Interface: pmod_gpio
        .pmod_gpi            (i_student_ss2_pmod_gpi),
        .pmod_gpio_oe        (i_student_ss2_pmod_gpio_oe),
        .pmod_gpo            (i_student_ss2_pmod_gpo));

    // IP-XACT VLNV: tuni.fi:tech:tech_cg:1.0
    tech_cg ss_cg(
        // Interface: clk_in
        .clk                 (ss_cg_clk),
        // Interface: clk_out
        .clk_out             (ss_cg_clk_out),
        // These ports are not in any interface
        .en                  (ss_cg_en));

    // IP-XACT VLNV: tuni.fi:tech:tech_cg:1.0
    tech_cg ss_high_speed_cg(
        // Interface: clk_in
        .clk                 (ss_high_speed_cg_clk),
        // Interface: clk_out
        .clk_out             (ss_high_speed_cg_clk_out),
        // These ports are not in any interface
        .en                  (ss_high_speed_cg_en));


endmodule
