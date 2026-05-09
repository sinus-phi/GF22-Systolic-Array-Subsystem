module pe #(
    parameter DATA_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,

    // Control signals
    input wire en,
    input wire i_load,
    output reg o_load,

    // Data signals
    input wire [DATA_WIDTH-1:0] i_data,
    output reg [DATA_WIDTH-1:0] o_data,
    input wire [DATA_WIDTH-1:0] i_sum,
    output reg [DATA_WIDTH-1:0] o_sum
);

reg [DATA_WIDTH-1:0] weight_reg;

always @(posedge clk) begin
    if(~rst_n) begin
        o_load <= 0;
    end
    else begin
        if(en) begin
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

endmodule