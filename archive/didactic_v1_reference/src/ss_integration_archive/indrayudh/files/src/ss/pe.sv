module pe #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = DATA_WIDTH*2,
    parameter MAC_STAGES = 2
)(
    input wire clk,
    input wire rst_n,

    // Control signals
    input wire en,
    input wire i_load,
    output reg o_load,

    // Data signals
    input wire signed [DATA_WIDTH-1:0] i_data,
    output reg signed [DATA_WIDTH-1:0] o_data,
    input wire signed [ACC_WIDTH-1:0] i_sum,
    output reg signed [ACC_WIDTH-1:0] o_sum
);

reg signed [DATA_WIDTH-1:0] weight_reg;

generate
    if (MAC_STAGES == 1) begin : gen_single_stage_mac
        always @(posedge clk) begin
            if(~rst_n) begin
                o_load <= 1'b0;
                o_data <= {DATA_WIDTH{1'b0}};
                o_sum <= {ACC_WIDTH{1'b0}};
                weight_reg <= {DATA_WIDTH{1'b0}};
            end
            else if(en) begin
                o_load <= i_load;
                o_data <= i_data;

                if(i_load) begin
                    weight_reg <= i_data;
                end
                else begin
                    o_sum <= i_data * weight_reg + i_sum;
                end
            end
        end
    end
    else begin : gen_multi_stage_mac
        integer stage;
        reg load_pipe [0:MAC_STAGES-2];
        reg signed [DATA_WIDTH-1:0] data_pipe [0:MAC_STAGES-2];
        reg signed [ACC_WIDTH-1:0] mul_pipe [0:MAC_STAGES-2];
        reg signed [ACC_WIDTH-1:0] sum_pipe [0:MAC_STAGES-2];

        always @(posedge clk) begin
            if(~rst_n) begin
                o_load <= 1'b0;
                o_data <= {DATA_WIDTH{1'b0}};
                o_sum <= {ACC_WIDTH{1'b0}};
                weight_reg <= {DATA_WIDTH{1'b0}};
                for(stage = 0; stage < MAC_STAGES-1; stage = stage + 1) begin
                    load_pipe[stage] <= 1'b0;
                    data_pipe[stage] <= {DATA_WIDTH{1'b0}};
                    mul_pipe[stage] <= {ACC_WIDTH{1'b0}};
                    sum_pipe[stage] <= {ACC_WIDTH{1'b0}};
                end
            end
            else if(en) begin
                load_pipe[0] <= i_load;
                data_pipe[0] <= i_data;
                if(i_load) begin
                    weight_reg <= i_data;
                    mul_pipe[0] <= {ACC_WIDTH{1'b0}};
                    sum_pipe[0] <= {ACC_WIDTH{1'b0}};
                end
                else begin
                    mul_pipe[0] <= i_data * weight_reg;
                    sum_pipe[0] <= i_sum;
                end

                for(stage = 1; stage < MAC_STAGES-1; stage = stage + 1) begin
                    load_pipe[stage] <= load_pipe[stage-1];
                    data_pipe[stage] <= data_pipe[stage-1];
                    mul_pipe[stage] <= mul_pipe[stage-1];
                    sum_pipe[stage] <= sum_pipe[stage-1];
                end

                o_load <= load_pipe[MAC_STAGES-2];
                o_data <= data_pipe[MAC_STAGES-2];
                o_sum <= mul_pipe[MAC_STAGES-2] + sum_pipe[MAC_STAGES-2];
            end
        end
    end
endgenerate

endmodule
