module sa #(
    parameter DATA_WIDTH = 32,
    parameter ARRAY_HEIGHT = 4,
    parameter ARRAY_WIDTH = 4
)(
    input wire clk,
    input wire rst_n,

    input wire en,
    input wire load,

    input wire [ARRAY_HEIGHT*DATA_WIDTH-1:0] i_data, //LSB -> top pe, MSB -> bottom pe
    output wire [ARRAY_WIDTH*DATA_WIDTH-1:0] o_data  //LSB -> left pe, MSB -> right pe
);

genvar h, w;

wire                     w_load [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire [DATA_WIDTH-1:0]    w_data [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire [DATA_WIDTH-1:0]    w_sum  [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];

generate
    for (h = 0; h < ARRAY_HEIGHT; h = h + 1) begin : gen_row
        for (w = 0; w < ARRAY_WIDTH; w = w + 1) begin : gen_col
            
            pe #(
                .DATA_WIDTH(DATA_WIDTH)
            ) pe_inst (
                .clk(clk),
                .rst_n(rst_n),
                .en(en),

                .i_load((h == 0) ? load : w_load[h-1][w]),
                .o_load(w_load[h][w]),

                .i_data((w == 0) ? i_data[DATA_WIDTH*h +: DATA_WIDTH] : w_data[h][w-1]),
                .o_data(w_data[h][w]),

                .i_sum((h == 0) ? {DATA_WIDTH{1'b0}} : w_sum[h-1][w]),
                .o_sum(w_sum[h][w])
            );

            if (h == ARRAY_HEIGHT - 1) begin : gen_output
                assign o_data[DATA_WIDTH*w +: DATA_WIDTH] = w_sum[h][w];
            end
        end
    end
endgenerate

endmodule