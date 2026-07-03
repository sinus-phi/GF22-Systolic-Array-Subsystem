/* =====================================
pe.sv - Processing Element for Systolic Array
AI Accelerator | Edu4Chip / Didactic SoC

Key Design Decisions:
- Weight-stationary dataflow
- Activations move left to right
- Partial sums move top to bottom
- dtype_sel[3:2] = weight type
- dtype_sel[1:0] = activation type
- 00 = INT4, 01 = INT8, 10 = INT16, 11 = INT32
===================================== */

module pe #(
    parameter int DATA_WIDTH = 32,
    parameter int ACC_WIDTH  = 67
)(
    input  wire                         clk_in,
    input  wire                         reset_int,

    // 0 = weight injection/load, 1 = activation compute
    input  logic                        row_inject_mode,

    // [3:2] weight type, [1:0] activation type
    input  logic [3:0]                  dtype_sel,

    // Control signals
    input  logic                        en,
    input  logic                        i_load,
    input  wire                         i_valid,
    output logic                        o_valid,

    // Data signals
    input  wire [DATA_WIDTH-1:0]        i_data,
    output logic [DATA_WIDTH-1:0]       o_data,

    input  wire signed [ACC_WIDTH-1:0]  i_partial,
    output logic signed [ACC_WIDTH-1:0] o_partial,

    input  logic                        i_partial_valid,
    output logic                        o_partial_valid,

    output logic                        overflow,

    // Synchronous clear for PE pipeline, not stationary weight
    input  wire                         clear
);

    localparam int PRODUCT_WIDTH = 2 * DATA_WIDTH;

    logic signed [DATA_WIDTH-1:0]      weight_reg;
    logic signed [DATA_WIDTH-1:0]      act_operand;
    logic signed [DATA_WIDTH-1:0]      wgt_operand;
    logic signed [PRODUCT_WIDTH-1:0]   product;
    logic signed [ACC_WIDTH-1:0]       product_ext;
    logic signed [ACC_WIDTH-1:0]       acc_next;

    logic                              compute_fire;
    logic                              add_overflow;

    // ------------------------------------------------------------
    // Sign extension for activation and weight operands
    // ------------------------------------------------------------

    always_comb begin
        unique case (dtype_sel[1:0])
            2'b00: act_operand = {{(DATA_WIDTH-4){i_data[3]}},   i_data[3:0]};
            2'b01: act_operand = {{(DATA_WIDTH-8){i_data[7]}},   i_data[7:0]};
            2'b10: act_operand = {{(DATA_WIDTH-16){i_data[15]}}, i_data[15:0]};
            2'b11: act_operand = $signed(i_data);
            default: act_operand = $signed(i_data);
        endcase

        unique case (dtype_sel[3:2])
            2'b00: wgt_operand = {{(DATA_WIDTH-4){weight_reg[3]}},   weight_reg[3:0]};
            2'b01: wgt_operand = {{(DATA_WIDTH-8){weight_reg[7]}},   weight_reg[7:0]};
            2'b10: wgt_operand = {{(DATA_WIDTH-16){weight_reg[15]}}, weight_reg[15:0]};
            2'b11: wgt_operand = weight_reg;
            default: wgt_operand = weight_reg;
        endcase
    end

    assign product = act_operand * wgt_operand;

    // Sign-extend product to accumulator width.
    assign product_ext = {{(ACC_WIDTH-PRODUCT_WIDTH){product[PRODUCT_WIDTH-1]}}, product};

    assign compute_fire = en && row_inject_mode && i_valid && i_partial_valid;
    assign acc_next     = i_partial + product_ext;

    // Signed addition overflow:
    // same-sign operands produce opposite-sign result.
    assign add_overflow =
        compute_fire &&
        (i_partial[ACC_WIDTH-1] == product_ext[ACC_WIDTH-1]) &&
        (acc_next[ACC_WIDTH-1]  != i_partial[ACC_WIDTH-1]);

    // ------------------------------------------------------------
    // Stationary weight register
    // Loaded only in weight injection mode.
    // Normal clear does not erase weights.
    // ------------------------------------------------------------

    always_ff @(posedge clk_in or negedge reset_int) begin
        if (!reset_int) begin
            weight_reg <= '0;
        end else if (en && i_load && !row_inject_mode) begin
            weight_reg <= $signed(i_data);
        end
    end

    // ------------------------------------------------------------
    // Horizontal activation/data movement
    // ------------------------------------------------------------

    always_ff @(posedge clk_in or negedge reset_int) begin
        if (!reset_int) begin
            o_data  <= '0;
            o_valid <= 1'b0;
        end else if (clear) begin
            o_data  <= '0;
            o_valid <= 1'b0;
        end else if (en) begin
            o_data  <= i_data;
            o_valid <= i_valid;
        end
    end

    // ------------------------------------------------------------
    // Vertical partial-sum movement and MAC
    // ------------------------------------------------------------

    always_ff @(posedge clk_in or negedge reset_int) begin
        if (!reset_int) begin
            o_partial       <= '0;
            o_partial_valid <= 1'b0;
            overflow        <= 1'b0;
        end else if (clear) begin
            o_partial       <= '0;
            o_partial_valid <= 1'b0;
            overflow        <= 1'b0;
        end else if (en) begin
            if (compute_fire) begin
                o_partial       <= acc_next;
                o_partial_valid <= 1'b1;
                overflow        <= add_overflow;
            end else begin
                o_partial       <= '0;
                o_partial_valid <= 1'b0;
                overflow        <= 1'b0;
            end
        end
    end

endmodule