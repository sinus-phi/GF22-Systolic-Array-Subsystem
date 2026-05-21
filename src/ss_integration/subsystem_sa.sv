`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Two-dimensional systolic array wrapper.
//
// The array preserves Indrayudh's original movement pattern:
//   - weights are loaded column-by-column through skewed load pulses,
//   - activations enter from the left with row-dependent skew,
//   - partial sums move downward through each column,
//   - completed bottom-row sums are deskewed before leaving the array.
//
// This module is datapath-only.  It does not know about APB, register fields,
// tile sizes, or firmware sequencing.
//-----------------------------------------------------------------------------

module subsystem_sa #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = DATA_WIDTH*2,
    parameter MAC_STAGES = 2,
    parameter ARRAY_HEIGHT = 4,
    parameter ARRAY_WIDTH = 4
)(
    input wire clk,
    input wire rst_n,

    input wire en,
    input wire [ARRAY_WIDTH-1:0] load, // LSB -> left column, MSB -> right column

    input wire [ARRAY_HEIGHT*DATA_WIDTH-1:0] i_data, // LSB -> top row, MSB -> bottom row
    output wire [ARRAY_WIDTH*ACC_WIDTH-1:0] o_data, // LSB -> left column, MSB -> right column
    output wire [ARRAY_WIDTH-1:0] o_overflow
);

genvar h, w;

// Delay the incoming load signal based on the column number.  This matches the
// horizontal movement of weight data so each column captures the intended
// weight vector element.
wire [ARRAY_WIDTH-1:0] load_skewed;
generate
    assign load_skewed[0] = load[0];
    for (w = 0; w < ARRAY_WIDTH-1; w = w + 1) begin : gen_load_skew
        localparam integer LOAD_DELAY = (w + 1) * MAC_STAGES;
        integer d;
        reg load_pipe [0:LOAD_DELAY-1];

        always @(posedge clk) begin
            if(~rst_n) begin
                for(d = 0; d < LOAD_DELAY; d = d + 1) begin
                    load_pipe[d] <= 1'b0;
                end
            end
            else if(en) begin
                load_pipe[0] <= load[w+1];
                for(d = 0; d < LOAD_DELAY-1; d = d + 1) begin
                    load_pipe[d+1] <= load_pipe[d];
                end
            end
        end
        assign load_skewed[w+1] = load_pipe[LOAD_DELAY-1];
    end
endgenerate

// Delay incoming row data into the proper systolic skew.  The top row consumes
// the vector immediately; each lower row is delayed by MAC_STAGES more cycles.
wire [DATA_WIDTH-1:0] data_skewed [ARRAY_HEIGHT-1:0];
generate
    assign data_skewed[0] = i_data[0+:DATA_WIDTH];
    for (h = 0; h < ARRAY_HEIGHT-1; h = h + 1) begin : gen_data_skew
        localparam integer DATA_DELAY = (h + 1) * MAC_STAGES;
        integer d;
        reg [DATA_WIDTH-1:0] data_pipe [0:DATA_DELAY-1];
        always @(posedge clk) begin
            if(~rst_n)
                for(d = 0; d < DATA_DELAY; d = d + 1)
                    data_pipe[d] <= {DATA_WIDTH{1'b0}};
                    
            else if(en) begin
                data_pipe[0] <= i_data[(h+1)*DATA_WIDTH+:DATA_WIDTH];
                for(d = 0; d < DATA_DELAY-1; d = d + 1)
                    data_pipe[d+1] <= data_pipe[d];
            end 
        end
        assign data_skewed[h+1] = data_pipe[DATA_DELAY-1];
    end
endgenerate

// Internal PE interconnects.  Data moves horizontally through w_data, load and
// partial sums move vertically through w_load/w_sum, and overflow follows the
// same vertical path as its corresponding partial sum.
wire                     w_load [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire [DATA_WIDTH-1:0]    w_data [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire [ACC_WIDTH-1:0]     w_sum  [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire                     w_overflow [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];
wire [ACC_WIDTH-1:0]     output_skewed [0:ARRAY_WIDTH-1];
wire                     output_overflow_skewed [0:ARRAY_WIDTH-1];

generate
    for (h = 0; h < ARRAY_HEIGHT; h = h + 1) begin : gen_row
        for (w = 0; w < ARRAY_WIDTH; w = w + 1) begin : gen_col

            wire pe_i_load;
            wire pe_i_overflow;
            wire [DATA_WIDTH-1:0] pe_i_data;
            wire [ACC_WIDTH-1:0] pe_i_sum;

            if (h == 0) begin : gen_top_input
                // Top row starts a new vertical partial-sum chain.
                assign pe_i_load = load_skewed[w];
                assign pe_i_overflow = 1'b0;
                assign pe_i_sum = {ACC_WIDTH{1'b0}};
            end
            else begin : gen_vertical_input
                // Non-top rows receive load/partial-sum state from the PE above.
                assign pe_i_load = w_load[h-1][w];
                assign pe_i_overflow = w_overflow[h-1][w];
                assign pe_i_sum = w_sum[h-1][w];
            end

            if (w == 0) begin : gen_left_input
                // Leftmost column receives the externally skewed activation data.
                assign pe_i_data = data_skewed[h];
            end
            else begin : gen_horizontal_input
                // Other columns receive the activation data forwarded from the
                // previous PE in the same row.
                assign pe_i_data = w_data[h][w-1];
            end

            subsystem_pe #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH(ACC_WIDTH),
                .MAC_STAGES(MAC_STAGES)
            ) pe_inst (
                .clk(clk),
                .rst_n(rst_n),
                .en(en),

                .i_load(pe_i_load),
                .i_overflow(pe_i_overflow),
                .o_load(w_load[h][w]),
                .o_overflow(w_overflow[h][w]),

                .i_data(pe_i_data),
                .o_data(w_data[h][w]),

                .i_sum(pe_i_sum),
                .o_sum(w_sum[h][w])
            );

            if (h == ARRAY_HEIGHT - 1) begin : gen_output
                assign output_skewed[w] = w_sum[h][w];
                assign output_overflow_skewed[w] = w_overflow[h][w];
            end
        end
    end
endgenerate

// Delay earlier columns so all output lanes correspond to the same wavefront.
// The original array only deskewed o_data.  Saturation adds an overflow sideband,
// so the flag is deskewed with the same delay to stay aligned with its result.
generate
    for (w = 0; w < ARRAY_WIDTH; w = w + 1) begin : gen_output_deskew
        if (w == ARRAY_WIDTH - 1) begin : gen_no_delay
            assign o_data[ACC_WIDTH*w +: ACC_WIDTH] = output_skewed[w];
            assign o_overflow[w] = output_overflow_skewed[w];
        end
        else begin : gen_delay
            localparam integer OUTPUT_DELAY = (ARRAY_WIDTH - 1 - w) * MAC_STAGES;
            integer d;
            reg [ACC_WIDTH-1:0] output_pipe [0:OUTPUT_DELAY-1];
            reg overflow_pipe [0:OUTPUT_DELAY-1];

            always @(posedge clk) begin
                if (~rst_n) begin
                    for (d = 0; d < OUTPUT_DELAY; d = d + 1) begin
                        output_pipe[d] <= {ACC_WIDTH{1'b0}};
                        overflow_pipe[d] <= 1'b0;
                    end
                end
                else if (en) begin
                    output_pipe[0] <= output_skewed[w];
                    overflow_pipe[0] <= output_overflow_skewed[w];
                    for (d = 0; d < OUTPUT_DELAY-1; d = d + 1) begin
                        output_pipe[d+1] <= output_pipe[d];
                        overflow_pipe[d+1] <= overflow_pipe[d];
                    end
                end
            end

            assign o_data[ACC_WIDTH*w +: ACC_WIDTH] = output_pipe[OUTPUT_DELAY-1];
            assign o_overflow[w] = overflow_pipe[OUTPUT_DELAY-1];
        end
    end
endgenerate

endmodule
