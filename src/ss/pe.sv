module pe #(
    parameter DATA_WIDTH = 32
)(
    input wire clk,
    input wire rst,

    // Control signals
    input wire en,
    input wire i_load,
    output reg o_load,

    // Data signals
    input wire [DATA_WIDTH-1:0] i_data,
    output reg [DATA_WIDTH-1:0] o_data,
    input wire [DATA_WIDTH-1:0] i_partial,
    output reg [DATA_WIDTH-1:0] o_partial,
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

endmodule