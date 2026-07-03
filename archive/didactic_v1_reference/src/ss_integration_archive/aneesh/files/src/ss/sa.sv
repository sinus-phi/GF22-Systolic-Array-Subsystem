module sa #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = 80,
    parameter ARRAY_HEIGHT = 8, 
    parameter ARRAY_WIDTH = 8
)(
    input wire clk_in,
    input wire reset_int,

    input wire en,
    input wire load,

    input wire [3:0] dtype_sel,
    input wire row_inject_mode,

    input wire [ARRAY_HEIGHT*DATA_WIDTH-1:0] i_data, // 8*32=256 bits wide input bus
    output wire [ARRAY_WIDTH*ACC_WIDTH-1:0] o_data, // 8*80=640 bits wide output bus

    input logic clear;
);

/*
- en triggers all PE's to take action this cycle
- load is triggered by input controller. connect to top row PEs
- i_data connects to left port to leftmost column of PEs
- o_data comes from bottom port of last row of PEs
*/
    //data_w - horizontal i_data chain
    // partial_w - vertical psum chain
    // load_w - load propagation chain from top to bottom
    logic [N-1:0][N:0][DATA_WIDTH-1:0] data_w; // internal wire
    logic [N:0][N-1:0][ACC_WIDTH-1:0] partial_w; // internal wire
    logic [N:0] load_w; // internal wire

    // Boundary conditions
    // i_data enters at left edge of each row
    for (genvar r = 0; r < N; r++) begin : gen_data_boundary
        assign data_w[r][0] = i_data[r*DATA_WIDTH +: DATA_WIDTH];
    end

    // partial sum enters as 0 at top edge for all columns
    for (genvar c = 0; c < N; c++) begin : gen_partial_boundary
        assign partial_w[0][c] = '0;
    end

    assign load_w[0] = i_load; // i_load enters at top row only

    // 8x8 PE array generation loop
    for (genvar r=0; r<N; r++) begin: g_row
        for (genvar c=0; c<N; c++) begin: g_col

            // o_data wire : horizontal chain to next column
            logic [DATA_WIDTH-1:0] o_data_wire;
            logic o_loafd_wire;

            pe #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH(ACC_WIDTH)
            ) pe_inst (
                .clk_in(clk_in),
                .reset_int(reset_int),
                .en(en),
                .i_load(load_w[r]),
                .o_load(o_load_wire), // propagate load to next row
                .dtype_sel(dtype_sel),
                .row_inject_mode(row_inject_mode),
                .i_data(data_w[r][c]),
                .o_data(o_data_wire),
                .i_partial(partial_w[r][c]),
                .o_partial(partial_w[r+1][c]),
                .clear(clear)
            );

            // connect horizontal data chain
            assign data_w[r][c+1] = o_data_wire;
            
            // col0 PE's o_load drives next row's i_load
            if (c == 0) begin : gen_load_chain
                assign load_w[r+1] = o_load_wire;
            end

        end
    end


    // o_data: pack partial_w bottom row to flat output bus
    for (genvar c = 0; c < N; c++) begin : gen_output_pack
        assign o_data[c*ACC_WIDTH +: ACC_WIDTH] = partial_w[N][c];
    end

endmodule