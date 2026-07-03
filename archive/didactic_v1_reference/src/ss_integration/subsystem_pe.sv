`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Processing element for the signed systolic array.
//
// During LOAD_WEIGHTS, i_load captures i_data into the local weight register and
// forwards the load pulse down the column.  During compute/drain, the PE
// multiplies the incoming signed data by the stored signed weight, adds the
// incoming vertical partial sum, saturates to ACC_WIDTH, and forwards both data
// and partial sum to neighboring PEs.
//-----------------------------------------------------------------------------

module subsystem_pe #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = DATA_WIDTH*2,
    parameter MAC_STAGES = 2
)(
    input wire clk,
    input wire rst_n,

    // Control signals
    input wire en,
    input wire i_load,
    input wire i_overflow,
    output reg o_load,
    output reg o_overflow,

    // Data signals
    input wire signed [DATA_WIDTH-1:0] i_data,
    output reg signed [DATA_WIDTH-1:0] o_data,
    input wire signed [ACC_WIDTH-1:0] i_sum,
    output reg signed [ACC_WIDTH-1:0] o_sum
);

// One stationary weight per PE.  Activations move horizontally; partial sums
// move vertically.
reg signed [DATA_WIDTH-1:0] weight_reg;

localparam int PRODUCT_WIDTH = DATA_WIDTH * 2;

localparam logic signed [ACC_WIDTH-1:0] ACC_MAX =
    {1'b0, {(ACC_WIDTH-1){1'b1}}};
localparam logic signed [ACC_WIDTH-1:0] ACC_MIN =
    {1'b1, {(ACC_WIDTH-1){1'b0}}};

function automatic logic signed [ACC_WIDTH-1:0] mac_product(
    input logic signed [DATA_WIDTH-1:0] data,
    input logic signed [DATA_WIDTH-1:0] weight
);
    logic signed [PRODUCT_WIDTH-1:0] product_native;
    begin
        // The original PE used an unchecked signed multiply-add.
        // The integration PE still accepts DATA_WIDTH-normalized operands from the
        // frontend, so keep the multiplier itself at DATA_WIDTH x DATA_WIDTH.

        // Do not sign-extend both operands to ACC_WIDTH before multiplying:
        // that can make synthesis infer a wider ACC_WIDTH x ACC_WIDTH
        // multiplier.  Instead, capture the native 2*DATA_WIDTH product and
        // only then sign-extend/truncate it to the accumulator width.
        product_native = data * weight;

        if (ACC_WIDTH > PRODUCT_WIDTH) begin
            mac_product = {{(ACC_WIDTH-PRODUCT_WIDTH){product_native[PRODUCT_WIDTH-1]}},
                           product_native};
        end else begin
            mac_product = product_native[ACC_WIDTH-1:0];
        end
    end
endfunction

function automatic logic add_overflow(
    input logic signed [ACC_WIDTH-1:0] lhs,
    input logic signed [ACC_WIDTH-1:0] rhs
);
    logic signed [ACC_WIDTH-1:0] raw_sum;
    begin
        raw_sum = lhs + rhs;
        // Signed overflow can only happen when operands have the same sign and
        // the result sign flips.
        add_overflow =
            (!lhs[ACC_WIDTH-1] && !rhs[ACC_WIDTH-1] &&  raw_sum[ACC_WIDTH-1]) ||
            ( lhs[ACC_WIDTH-1] &&  rhs[ACC_WIDTH-1] && !raw_sum[ACC_WIDTH-1]);
    end
endfunction

function automatic logic signed [ACC_WIDTH-1:0] sat_add(
    input logic signed [ACC_WIDTH-1:0] lhs,
    input logic signed [ACC_WIDTH-1:0] rhs
);
    logic signed [ACC_WIDTH-1:0] raw_sum;
    begin
        raw_sum = lhs + rhs;
        // Clamp instead of wrapping.  The sideband overflow flag lets firmware
        // decide how to report or post-process saturated results.
        if (!lhs[ACC_WIDTH-1] && !rhs[ACC_WIDTH-1] && raw_sum[ACC_WIDTH-1]) begin
            sat_add = ACC_MAX;
        end else if (lhs[ACC_WIDTH-1] && rhs[ACC_WIDTH-1] && !raw_sum[ACC_WIDTH-1]) begin
            sat_add = ACC_MIN;
        end else begin
            sat_add = raw_sum;
        end
    end
endfunction

generate
    if (MAC_STAGES == 1) begin : gen_single_stage_mac
        logic signed [ACC_WIDTH-1:0] product;

        always @(posedge clk) begin
            if(~rst_n) begin
                o_load <= 1'b0;
                o_overflow <= 1'b0;
                o_data <= {DATA_WIDTH{1'b0}};
                o_sum <= {ACC_WIDTH{1'b0}};
                weight_reg <= {DATA_WIDTH{1'b0}};
            end
            else if(en) begin
                o_load <= i_load;
                o_data <= i_data;

                if(i_load) begin
                    // Weight-load cycle: store the signed operand and suppress
                    // MAC overflow because no accumulation is performed.
                    weight_reg <= i_data;
                    o_overflow <= 1'b0;
                end
                else begin
                    // Compute cycle: activation/data moves right, partial sum
                    // moves down, and overflow is accumulated through the column.
                    product = mac_product(i_data, weight_reg);
                    o_sum <= sat_add(product, i_sum);
                    o_overflow <= i_overflow | add_overflow(product, i_sum);
                end
            end
        end
    end
    else begin : gen_multi_stage_mac
        integer stage;
        reg load_pipe [0:MAC_STAGES-2];
        reg overflow_pipe [0:MAC_STAGES-2];
        reg signed [DATA_WIDTH-1:0] data_pipe [0:MAC_STAGES-2];
        reg signed [ACC_WIDTH-1:0] mul_pipe [0:MAC_STAGES-2];
        reg signed [ACC_WIDTH-1:0] sum_pipe [0:MAC_STAGES-2];
        logic signed [ACC_WIDTH-1:0] product;

        always @(posedge clk) begin
            if(~rst_n) begin
                o_load <= 1'b0;
                o_overflow <= 1'b0;
                o_data <= {DATA_WIDTH{1'b0}};
                o_sum <= {ACC_WIDTH{1'b0}};
                weight_reg <= {DATA_WIDTH{1'b0}};
                for(stage = 0; stage < MAC_STAGES-1; stage = stage + 1) begin
                    load_pipe[stage] <= 1'b0;
                    overflow_pipe[stage] <= 1'b0;
                    data_pipe[stage] <= {DATA_WIDTH{1'b0}};
                    mul_pipe[stage] <= {ACC_WIDTH{1'b0}};
                    sum_pipe[stage] <= {ACC_WIDTH{1'b0}};
                end
            end
            else if(en) begin
                load_pipe[0] <= i_load;
                data_pipe[0] <= i_data;
                if(i_load) begin
                    // Load path uses the same pipeline length as compute so
                    // downstream PEs stay aligned with the systolic timing.
                    weight_reg <= i_data;
                    mul_pipe[0] <= {ACC_WIDTH{1'b0}};
                    sum_pipe[0] <= {ACC_WIDTH{1'b0}};
                    overflow_pipe[0] <= 1'b0;
                end
                else begin
                    // Saturation is evaluated on the same product/sum pair as
                    // the original MAC, then pipelined with the result so the
                    // flag remains aligned to o_sum.
                    product = mac_product(i_data, weight_reg);
                    mul_pipe[0] <= product;
                    sum_pipe[0] <= i_sum;
                    overflow_pipe[0] <= i_overflow | add_overflow(product, i_sum);
                end

                for(stage = 1; stage < MAC_STAGES-1; stage = stage + 1) begin
                    load_pipe[stage] <= load_pipe[stage-1];
                    overflow_pipe[stage] <= overflow_pipe[stage-1];
                    data_pipe[stage] <= data_pipe[stage-1];
                    mul_pipe[stage] <= mul_pipe[stage-1];
                    sum_pipe[stage] <= sum_pipe[stage-1];
                end

                o_load <= load_pipe[MAC_STAGES-2];
                o_overflow <= overflow_pipe[MAC_STAGES-2];
                o_data <= data_pipe[MAC_STAGES-2];
                o_sum <= sat_add(mul_pipe[MAC_STAGES-2], sum_pipe[MAC_STAGES-2]);
            end
        end
    end
endgenerate

endmodule
