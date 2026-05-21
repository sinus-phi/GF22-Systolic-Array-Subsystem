/* =====================================
pe.sv - Processing Element for Systolic Array 
AI Accelerator | Edu4Chip / Didactic SoC
Dummy Behaviour Module

Key Design Decisions:
- WS Dataflow
- 32-bit FIFO for Input Row Injection of each row

*/

module pe #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = 64
)(
    input  wire                  clk_in,
    input  wire                  reset_int,

    //Injection Mode
    input  logic                 row_inject_mode, // 0 = weight injection, 1 = activation injection
    // [3:2] weight type, [1:0] act type
    // Data type selector 00=INT4, 01=INT8, 10=INT16, 11=INT32
    input  logic [3:0]           dtype_sel, 
    
    // Control signals
    input  logic                 en,  // If low, PE holds all state and drives no outputs.
    input  wire                  i_valid, 
    output reg                   o_valid,

    // Data signals
    input  wire [DATA_WIDTH-1:0] i_data,
    output reg [DATA_WIDTH-1:0]  o_data,
    input  wire [ACC_WIDTH-1:0]  i_partial,
    output reg [ACC_WIDTH-1:0]   o_partial,

    input  logic                 i_partial_valid, // indicates if i_partial is valid (for CALC mode)
    output logic                 o_partial_valid, // indicates if o_partial is valid (for CALC mode

    output logic                 overflow
    input  wire                  clear // synchronous clear for accumulator
);
/*
- if en is low, do nothing
- i_data comes from left and goes out through o_data (right).
- load signal comes from top and passed to bottom.

TWO modes of operation - 

LOAD - i_data is loaded into internal weight register.
CALC - o_partial <= i_partial + i_data * weight_reg;

-- add additional control signal to select (INT8, INT16, etc)
*/
logic signed [DATA_WIDTH-1:0]   weight_reg;
logic signed [DATA_WIDTH-1:0]   act_operand;
logic signed [DATA_WIDTH-1:0]   wgt_operand;
logic signed [2*DATA_WIDTH-1:0] product;
logic signed [ACC_WIDTH-1:0]    acc_next;
logic                           compute_fire;

// Sign extension logic for activation and weight operands based on dtype_sel
always_comb begin
    unique case (dtype_sel[1:0])
        2'b00: act_operand = {{(DATA_WIDTH-4){i_data[3]}},   i_data[3:0]};
        2'b01: act_operand = {{(DATA_WIDTH-8){i_data[7]}},   i_data[7:0]};
        2'b10: act_operand = {{(DATA_WIDTH-16){i_data[15]}}, i_data[15:0]};
        2'b11: act_operand = $signed(i_data);
        default: act_operand = {{(DATA_WIDTH-8){i_data[7]}}, i_data[7:0]};
    endcase

    unique case (dtype_sel[3:2])
        2'b00: wgt_operand = {{(DATA_WIDTH-4){weight_reg[3]}},   weight_reg[3:0]};
        2'b01: wgt_operand = {{(DATA_WIDTH-8){weight_reg[7]}},   weight_reg[7:0]};
        2'b10: wgt_operand = {{(DATA_WIDTH-16){weight_reg[15]}}, weight_reg[15:0]};
        2'b11: wgt_operand = weight_reg;
        default: wgt_operand = {{(DATA_WIDTH-8){weight_reg[7]}}, weight_reg[7:0]};
    endcase
end

assign product      = act_operand * wgt_operand;
assign acc_next     = $signed(i_partial) + ACC_WIDTH'($signed(product));    
assign compute_fire = en && row_inject_mode && i_valid && i_partial_valid;

// Weight Stationary Register Logic
always_ff @(posedge clk_in or negedge reset_int) begin
    if (!reset_int) begin
        weight_reg <= '0;
    end else if (en && i_load && (row_inject_mode == 1'b0)) begin
        weight_reg <= i_data; 
    end else if (clear) begin
        weight_reg <= '0; // Clear weight register on clear signal
    end
end

// Horizontal data movement, Checks for valid signals
always_ff @(posedge clk_in or negedge reset_int) begin
    if (!reset_int) begin
        o_data <= '0;
        o_valid <= 0;
    end else if (clear) begin
        o_data <= '0;
        o_valid <= 0;
    end else if (en) begin
        o_data <= i_data;
        o_valid <= i_valid;
    end
end

// Vertical partial sums accumulation and valid signal generation
always_ff @(posedge clk_in or negedge reset_int) begin
    if (!reset_int) begin
        o_partial <= '0;
        o_partial_valid <= 0;
    end else if (clear) begin
        o_partial <= '0;
        o_partial_valid <= 0;
    end else if (en) begin
        if (compute_fire) begin
            o_partial <= acc_next;
            o_partial_valid <= 1;
        end else begin
            o_partial <= i_partial; // Hold previous partial sum if not computing
            o_partial_valid <= 0;
        end
        
    end
end

endmodule