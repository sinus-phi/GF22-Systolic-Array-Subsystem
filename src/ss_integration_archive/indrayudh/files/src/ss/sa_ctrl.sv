module sa_ctrl #(
    parameter DATA_WIDTH = 32,
    parameter ACC_WIDTH = DATA_WIDTH*2,
    parameter MAC_STAGES = 2,
    parameter ARRAY_HEIGHT = 8,
    parameter ARRAY_WIDTH = 8,
    parameter BUFF_ADDR_WIDTH = 10,
    localparam OUTPUT_DATA_WIDTH = ACC_WIDTH*ARRAY_WIDTH,
    localparam OUTPUT_BYTES_PER_BEAT = OUTPUT_DATA_WIDTH/8,
    localparam OUTPUT_MAX_BEATS = (1 << BUFF_ADDR_WIDTH)/OUTPUT_BYTES_PER_BEAT,
    localparam ROW_CNTR_WIDTH = $clog2(OUTPUT_MAX_BEATS + 1),
    localparam BUFF_CNTR_WIDTH = $clog2(ARRAY_HEIGHT + 1),
    localparam OUTPUT_START_CYCLES = (ARRAY_HEIGHT + ARRAY_WIDTH - 1) * MAC_STAGES,
    localparam DRAIN_CYCLES = (ARRAY_WIDTH - 1) * MAC_STAGES + 1,
    localparam DRAIN_CNTR_WIDTH = $clog2(DRAIN_CYCLES + 1),
    localparam OUT_CNTR_WIDTH = $clog2(OUTPUT_MAX_BEATS + OUTPUT_START_CYCLES + 1)
)(
    input wire clk,
    input wire rst_n,

    // Input data from APB. Software writes little-endian words:
    // i_data[7:0] is the lowest-addressed byte and first packed element.
    input wire [31:0] i_data,
    input wire i_valid,

    // Control signals from APB controller
    input wire ctrl_en,
    input wire ctrl_instr,
    input wire [1:0] ctrl_dtype,
    input wire [BUFF_ADDR_WIDTH-1:0] ctrl_out_addr,
    input wire [ROW_CNTR_WIDTH-1:0] ctrl_rows,

    output wire [1:0] o_state,
    output reg done,

    // Output data to output buffer. wr_data lane 0 is in the least-significant
    // ACC_WIDTH bits so APB reads from the lowest byte offset return result 0.
    output reg wr_en,
    output reg [BUFF_ADDR_WIDTH-1:0] addr,
    output reg [OUTPUT_DATA_WIDTH-1:0] wr_data
);

localparam DTYPE_INT4  = 2'd0;
localparam DTYPE_INT8  = 2'd1;
localparam DTYPE_INT16 = 2'd2;
localparam DTYPE_INT32 = 2'd3;

localparam INSTR_LOAD = 1'b1;
localparam INSTR_GEMM = 1'b0;

localparam S_IDLE  = 2'd0;
localparam S_READY = 2'd1;
localparam S_DRAIN = 2'd2;

localparam OUT_IDLE  = 2'd0;
localparam OUT_WAIT  = 2'd1;
localparam OUT_WRITE = 2'd2;
localparam OUT_DONE  = 2'd3;

localparam [ROW_CNTR_WIDTH-1:0] ROW_COUNT_ONE = 1;
localparam [BUFF_ADDR_WIDTH-1:0] OUTPUT_ADDR_STRIDE = OUTPUT_BYTES_PER_BEAT;

// Main transaction FSM state
reg [1:0] state;
reg instr_reg;
reg [1:0] dtype_reg;
reg [ROW_CNTR_WIDTH-1:0] rows_reg;
reg [DRAIN_CNTR_WIDTH-1:0] main_counter;
reg push_to_sa;

// Input buffer and data decoder
reg [BUFF_CNTR_WIDTH-1:0] buff_counter;
reg [DATA_WIDTH-1:0] input_buffer [0:ARRAY_HEIGHT-1];
reg [DATA_WIDTH-1:0] decoded_elem [0:7];
reg [3:0] elems_this_word;

// Systolic array interface
wire [OUTPUT_DATA_WIDTH-1:0] sa_o_data;
wire [ARRAY_HEIGHT*DATA_WIDTH-1:0] sa_i_data;
reg [ARRAY_WIDTH-1:0] sa_load;
reg sa_en;

// Output write FSM state
reg [1:0] out_state;
reg [OUT_CNTR_WIDTH-1:0] out_counter;
reg [BUFF_ADDR_WIDTH-1:0] out_base_addr;

integer idx;
integer elem_idx;
integer dec_idx;

assign o_state = state;

// Systolic array input packing
genvar row;
generate
    for (row = 0; row < ARRAY_HEIGHT; row = row + 1) begin : gen_sa_input
        assign sa_i_data[DATA_WIDTH*row +: DATA_WIDTH] =
            (state == S_DRAIN) ? '0 : input_buffer[row];
    end
endgenerate

// Systolic array instance
sa #(
    .DATA_WIDTH(DATA_WIDTH),
    .ACC_WIDTH(ACC_WIDTH),
    .MAC_STAGES(MAC_STAGES),
    .ARRAY_HEIGHT(ARRAY_HEIGHT),
    .ARRAY_WIDTH(ARRAY_WIDTH)
) systolic_array (
    .clk(clk),
    .rst_n(rst_n),
    .en(sa_en),
    .load(sa_load),
    .i_data(sa_i_data),
    .o_data(sa_o_data)
);

// Data decoder
always @(*) begin
    elems_this_word = 4'd1;
    for (dec_idx = 0; dec_idx < 8; dec_idx = dec_idx + 1) begin
        decoded_elem[dec_idx] = '0;
    end

    case (dtype_reg)
        DTYPE_INT4: begin
            elems_this_word = 4'd8;
            for (dec_idx = 0; dec_idx < 8; dec_idx = dec_idx + 1) begin
                decoded_elem[dec_idx][3:0] = i_data[4*dec_idx +: 4];
            end
        end

        DTYPE_INT8: begin
            elems_this_word = 4'd4;
            for (dec_idx = 0; dec_idx < 4; dec_idx = dec_idx + 1) begin
                decoded_elem[dec_idx][7:0] = i_data[8*dec_idx +: 8];
            end
        end

        DTYPE_INT16: begin
            elems_this_word = 4'd2;
            for (dec_idx = 0; dec_idx < 2; dec_idx = dec_idx + 1) begin
                decoded_elem[dec_idx][15:0] = i_data[16*dec_idx +: 16];
            end
        end

        default: begin
            elems_this_word = 4'd1;
            decoded_elem[0] = i_data;
        end
    endcase
end

// Main FSM combinational control
always @(*) begin
    push_to_sa = 1'b0;
    sa_en = 1'b0;
    sa_load = '0;

    push_to_sa = (buff_counter == ARRAY_HEIGHT) && (state == S_READY);
    sa_en = push_to_sa || (state == S_DRAIN);

    if (push_to_sa && (instr_reg == INSTR_LOAD) && (main_counter < ARRAY_WIDTH)) begin
        sa_load[ARRAY_WIDTH - 1 - main_counter] = 1'b1;
    end
end

// Main transaction FSM
always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        instr_reg <= INSTR_LOAD;
        dtype_reg <= DTYPE_INT32;
        rows_reg <= '0;
        buff_counter <= '0;
        main_counter <= '0;
        done <= 1'b0;
        for (idx = 0; idx < ARRAY_HEIGHT; idx = idx + 1) begin
            input_buffer[idx] <= '0;
        end
    end
    else begin
        done <= 1'b0;

        case (state)
            S_IDLE: begin
                buff_counter <= '0;
                main_counter <= '0;
                if (ctrl_en) begin
                    state <= S_READY;
                    instr_reg <= ctrl_instr;
                    dtype_reg <= ctrl_dtype;
                    rows_reg <= ctrl_rows;
                end
            end

            S_READY: begin
                if (push_to_sa) begin
                    main_counter <= main_counter + 1'b1;
                    buff_counter <= '0;

                    if (i_valid) begin
                        for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                            if ((elem_idx < elems_this_word) && (elem_idx < ARRAY_HEIGHT)) begin
                                input_buffer[elem_idx] <= decoded_elem[elem_idx];
                                buff_counter <= elem_idx + 1'b1;
                            end
                        end
                    end

                    if ((main_counter + 1'b1) >= rows_reg) begin
                        state <= S_DRAIN;
                        main_counter <= '0;
                    end
                end
                else begin
                    if (i_valid && (buff_counter < ARRAY_HEIGHT)) begin
                        for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
                            if ((elem_idx < elems_this_word) &&
                                ((buff_counter + elem_idx) < ARRAY_HEIGHT)) begin
                                input_buffer[buff_counter + elem_idx] <= decoded_elem[elem_idx];
                                buff_counter <= buff_counter + elem_idx + 1'b1;
                            end
                        end
                    end
                end
            end

            S_DRAIN: begin
                buff_counter <= '0;

                if (((instr_reg == INSTR_LOAD) && (main_counter == (DRAIN_CYCLES - 1))) ||
                    ((instr_reg == INSTR_GEMM) && (out_state == OUT_DONE))) begin
                    state <= S_IDLE;
                    main_counter <= '0;
                    done <= 1'b1;
                end
                else begin
                    main_counter <= main_counter + 1'b1;
                end
            end
        endcase
    end
end

// Output write FSM
always @(posedge clk) begin
    if (!rst_n) begin
        out_state <= OUT_IDLE;
        out_counter <= '0;
        out_base_addr <= '0;
        wr_en <= 1'b0;
        addr <= '0;
        wr_data <= '0;
    end
    else begin
        wr_en <= 1'b0;

        case (out_state)
            OUT_IDLE: begin
                out_counter <= '0;

                if ((state == S_IDLE) && ctrl_en && (ctrl_instr == INSTR_GEMM)) begin
                    out_state <= OUT_WAIT;
                    out_base_addr <= ctrl_out_addr;
                end
            end

            OUT_WAIT: begin
                if (sa_en) begin
                    if (out_counter >= OUTPUT_START_CYCLES) begin
                        wr_en <= 1'b1;
                        wr_data <= sa_o_data;
                        addr <= out_base_addr;
                        out_counter <= ROW_COUNT_ONE;

                        if (rows_reg <= ROW_COUNT_ONE) begin
                            out_state <= OUT_DONE;
                        end
                        else begin
                            out_state <= OUT_WRITE;
                        end
                    end
                    else begin
                        out_counter <= out_counter + 1'b1;
                    end
                end
            end

            OUT_WRITE: begin
                if (sa_en) begin
                    wr_en <= 1'b1;
                    wr_data <= sa_o_data;
                    addr <= out_base_addr + (out_counter * OUTPUT_ADDR_STRIDE);

                    if ((out_counter + 1'b1) >= rows_reg) begin
                        out_state <= OUT_DONE;
                    end

                    out_counter <= out_counter + 1'b1;
                end
            end

            OUT_DONE: begin
                if (state == S_IDLE) begin
                    out_state <= OUT_IDLE;
                end
            end
        endcase
    end
end

endmodule
