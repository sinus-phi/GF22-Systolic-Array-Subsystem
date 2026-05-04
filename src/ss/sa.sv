module sa #(
    parameter DATA_WIDTH = 32,
    parameter ARRAY_HEIGHT = 4,
    parameter ARRAY_WIDTH = 4
)(
    input wire clk,
    input wire rst,

    input wire en,
    input wire load,

    input wire [ARRAY_HEIGHT*DATA_WIDTH-1:0] i_data,
    output wire [ARRAY_WIDTH*DATA_WIDTH-1:0] o_data,
);

/*
- en triggers all PE's to take action this cycle
- load is triggered by input controller. connect to top row PEs
- i_data connects to left port to leftmost column of PEs
- o_data comes from bottom port of last row of PEs
*/

endmodule