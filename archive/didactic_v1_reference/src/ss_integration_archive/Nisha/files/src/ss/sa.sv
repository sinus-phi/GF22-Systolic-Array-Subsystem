import systolic_precision_pkg::*;

module systolic_array_8x8 #(
    parameter int ARRAY_HEIGHT = 8,
    parameter int ARRAY_WIDTH  = 8,
    parameter int DATA_WIDTH   = 32,
    parameter int ACC_WIDTH    = 67
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        sa_clear,

    input  logic                        row_start,
    input  logic [2:0]                  current_row,
    input  logic [3:0]                  precision_mode,

    input  logic [DATA_WIDTH-1:0]       a_row [0:ARRAY_HEIGHT-1],

    input  logic                        weight_we,
    input  logic [5:0]                  weight_addr,
    input  logic [DATA_WIDTH-1:0]       weight_wdata,

    output logic                        row_busy,
    output logic                        row_done,

    output logic signed [ACC_WIDTH-1:0] result_data,
    output logic                        result_valid,
    input  logic                        result_ready,
    output logic [2:0]                  result_row,
    output logic [2:0]                  result_col,
    output logic                        result_last,
    output logic                        result_overflow
);

    typedef enum logic [1:0] {
        SA_IDLE,
        SA_RUN,
        SA_EMIT
    } sa_state_t;

    sa_state_t state;

    logic [4:0] cycle_count;
    logic [2:0] emit_col;

    logic [DATA_WIDTH-1:0] act_bus       [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH];
    logic                  act_valid_bus [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH];

    logic signed [ACC_WIDTH-1:0] psum_bus       [0:ARRAY_HEIGHT][0:ARRAY_WIDTH-1];
    logic                        psum_valid_bus [0:ARRAY_HEIGHT][0:ARRAY_WIDTH-1];
    logic                        overflow_bus   [0:ARRAY_HEIGHT][0:ARRAY_WIDTH-1];

    logic signed [ACC_WIDTH-1:0] row_result_buf [0:ARRAY_WIDTH-1];
    logic                        row_overflow_buf [0:ARRAY_WIDTH-1];
    logic [ARRAY_WIDTH-1:0]      row_result_valid;

    logic weight_load_en [0:ARRAY_HEIGHT-1][0:ARRAY_WIDTH-1];

    genvar r, c;

    generate
        for (r = 0; r < ARRAY_HEIGHT; r++) begin : WEIGHT_ROW
            for (c = 0; c < ARRAY_WIDTH; c++) begin : WEIGHT_COL
                assign weight_load_en[r][c] =
                    weight_we && (weight_addr == ((r * ARRAY_WIDTH) + c));
            end
        end
    endgenerate

    generate
        for (r = 0; r < ARRAY_HEIGHT; r++) begin : INPUT_BOUNDARY
            assign act_bus[r][0] =
                (state == SA_RUN &&
                 cycle_count < ARRAY_HEIGHT &&
                 cycle_count[2:0] == r[2:0])
                ? a_row[r] : '0;

            assign act_valid_bus[r][0] =
                (state == SA_RUN &&
                 cycle_count < ARRAY_HEIGHT &&
                 cycle_count[2:0] == r[2:0]);
        end
    endgenerate

    generate
        for (c = 0; c < ARRAY_WIDTH; c++) begin : TOP_BOUNDARY
            assign psum_bus[0][c]       = '0;
            assign psum_valid_bus[0][c] = act_valid_bus[0][c];
            assign overflow_bus[0][c]   = 1'b0;
        end
    endgenerate

    generate
        for (r = 0; r < ARRAY_HEIGHT; r++) begin : PE_ROW
            for (c = 0; c < ARRAY_WIDTH; c++) begin : PE_COL
                systolic_pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .sa_clear(sa_clear),
                    .pe_enable(state == SA_RUN),

                    .weight_load_en(weight_load_en[r][c]),
                    .weight_load_data(weight_wdata),
                    .precision_mode(precision_mode),

                    .act_in(act_bus[r][c]),
                    .act_valid_in(act_valid_bus[r][c]),

                    .psum_in(psum_bus[r][c]),
                    .psum_valid_in(psum_valid_bus[r][c]),
                    .overflow_in(overflow_bus[r][c]),

                    .act_out(act_bus[r][c+1]),
                    .act_valid_out(act_valid_bus[r][c+1]),

                    .psum_out(psum_bus[r+1][c]),
                    .psum_valid_out(psum_valid_bus[r+1][c]),
                    .overflow_out(overflow_bus[r+1][c])
                );
            end
        end
    endgenerate

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || sa_clear) begin
            state            <= SA_IDLE;
            cycle_count      <= '0;
            emit_col         <= '0;
            row_result_valid <= '0;
            row_done         <= 1'b0;
        end else begin
            row_done <= 1'b0;

            case (state)

                SA_IDLE: begin
                    cycle_count      <= '0;
                    emit_col         <= '0;
                    row_result_valid <= '0;

                    if (row_start)
                        state <= SA_RUN;
                end

                SA_RUN: begin
                    cycle_count <= cycle_count + 5'd1;

                    for (i = 0; i < ARRAY_WIDTH; i++) begin
                        if (psum_valid_bus[ARRAY_HEIGHT][i]) begin
                            row_result_buf[i]   <= psum_bus[ARRAY_HEIGHT][i];
                            row_overflow_buf[i] <= overflow_bus[ARRAY_HEIGHT][i];
                            row_result_valid[i] <= 1'b1;
                        end
                    end

                    if (&row_result_valid)
                        state <= SA_EMIT;
                end

                SA_EMIT: begin
                    if (result_valid && result_ready) begin
                        if (emit_col == ARRAY_WIDTH-1) begin
                            emit_col <= '0;
                            row_done <= 1'b1;
                            state    <= SA_IDLE;
                        end else begin
                            emit_col <= emit_col + 3'd1;
                        end
                    end
                end

                default: begin
                    state <= SA_IDLE;
                end

            endcase
        end
    end

    assign result_valid    = (state == SA_EMIT) && row_result_valid[emit_col];
    assign result_data     = row_result_buf[emit_col];
    assign result_row      = current_row;
    assign result_col      = emit_col;
    assign result_last     = (emit_col == ARRAY_WIDTH-1);
    assign result_overflow = row_overflow_buf[emit_col];

    assign row_busy = (state != SA_IDLE);

endmodule
