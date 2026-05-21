`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07.05.2026 20:35:37
// Design Name: 
// Module Name: control
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module control_unit #(
    parameter int COUNT_WIDTH = 16
)(
    
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    input  logic clear_done,
    input  logic clear_error,

    input  logic config_valid,
    input  logic dim_valid,


    input  logic row_write_valid,
    input  logic row_write_ready,

    input  logic fifo_full,
    input  logic fifo_empty,
    input  logic result_valid,
    input  logic result_ready,
    input  logic output_buffer_full,
    input  logic output_write_done,

    input  logic [COUNT_WIDTH-1:0] expected_weight_tokens,
    input  logic [COUNT_WIDTH-1:0] expected_act_tokens,
    input  logic [COUNT_WIDTH-1:0] expected_results,

    input  logic illegal_access,
    input  logic invalid_state_transition,
    input  logic timeout_error,

    output logic [2:0] state,
    output logic done,
    output logic error,
    output logic irq,

    output logic frontend_enable,
    output logic frontend_accept_enable,
    output logic frontend_flush,

    output logic row_inject_enable,
    output logic row_inject_mode,

    output logic fifo_write_enable,
    output logic fifo_read_enable,
    output logic fifo_flush,

    output logic scheduler_enable,
    output logic scheduler_weight_mode,
    output logic scheduler_activation_mode,

    output logic sa_enable,
    output logic sa_compute_enable,
    output logic sa_weight_load_enable,
    output logic sa_pipeline_drain_enable,

    output logic output_accept_enable,
    output logic output_write_enable,
    output logic output_window_valid,

    output logic [COUNT_WIDTH-1:0] weight_count_out,
    output logic [COUNT_WIDTH-1:0] act_count_out,
    output logic [COUNT_WIDTH-1:0] result_count_out
        
);


    logic [COUNT_WIDTH-1:0] weight_count;
    logic [COUNT_WIDTH-1:0] act_count;
    logic [COUNT_WIDTH-1:0] result_count;
    
                 //STATES
    typedef enum logic [2:0] {
        IDLE_CFG            = 3'd0,//No data movement, computation
        WEIGHT_MAP          = 3'd1,//Loads weight to PE
        ACT_STREAM_COMPUTE  = 3'd2,//Computation 
        DRAIN_WRITEBACK     = 3'd3,//Pipeline draining
        DONE                = 3'd4,//Output read back signal
        ERROR               = 3'd5 //Safe shutdown stage
    } state_cu;

    state_cu current_state;
    state_cu next_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            current_state <= IDLE_CFG;
        else
            current_state <= next_state;
        end

                    //State transition logic

    always_comb begin
        next_state = current_state;
           case(current_state)

            IDLE_CFG: begin
                if (illegal_access ||invalid_state_transition ||timeout_error)
                begin
                    next_state = ERROR;
                end
                else if (start && config_valid && dim_valid)
                begin
                    next_state = WEIGHT_MAP;
                end
             end

            WEIGHT_MAP: begin
                if (illegal_access ||timeout_error)
                begin
                    next_state = ERROR;
                end
                else if (weight_count == expected_weight_tokens)
                begin
                    next_state = ACT_STREAM_COMPUTE;
                end
             end

            ACT_STREAM_COMPUTE: begin
                if (illegal_access ||timeout_error)
                begin
                    next_state = ERROR;
                end
                else if (act_count == expected_act_tokens)
                begin
                    next_state = DRAIN_WRITEBACK;
                end
             end
             
            DRAIN_WRITEBACK: begin
                if (illegal_access ||timeout_error)
                begin
                    next_state = ERROR;
                end
                else if (result_count == expected_results && output_write_done)
                begin
                    next_state = DONE;
                end
             end

            DONE: begin
                if (clear_done)
                    next_state = IDLE_CFG;
                end

            ERROR: begin
                if (clear_error)
                    next_state = IDLE_CFG;
                end

           default: begin
                next_state = ERROR;
            end
         endcase
       end

    
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            weight_count <= '0;
            act_count    <= '0;
            result_count <= '0;

        end
        else begin

            // RESET COUNTERS IN IDLE
            if (current_state == IDLE_CFG) begin

                weight_count <= '0;
                act_count    <= '0;
                result_count <= '0;

            end
            
            // WEIGHT COUNT
            if (current_state == WEIGHT_MAP && row_write_valid && row_write_ready)
            begin
                weight_count <= weight_count + 1'b1;
            end

            // ACTIVATION COUNT
            if (current_state == ACT_STREAM_COMPUTE && row_write_valid && row_write_ready)
            begin
                act_count <= act_count + 1'b1;
            end

            // RESULT COUNT
            if (current_state == DRAIN_WRITEBACK &&result_valid && result_ready)
            begin
                result_count <= result_count + 1'b1;
            end
         end
       end

    always_comb begin
        // DEFAULT VALUES

        frontend_enable             = 1'b0;
        frontend_accept_enable      = 1'b0;
        frontend_flush              = 1'b0;

        row_inject_enable           = 1'b0;
        row_inject_mode             = 1'b0;

        fifo_write_enable           = 1'b0;
        fifo_read_enable            = 1'b0;
        fifo_flush                  = 1'b0;

        scheduler_enable            = 1'b0;
        scheduler_weight_mode       = 1'b0;
        scheduler_activation_mode   = 1'b0;

        sa_enable                   = 1'b0;
        sa_compute_enable           = 1'b0;
        sa_weight_load_enable       = 1'b0;
        sa_pipeline_drain_enable    = 1'b0;

        output_accept_enable        = 1'b0;
        output_write_enable         = 1'b0;
        output_window_valid         = 1'b0;

          //CONTROL LOGIC
        case(current_state)

            IDLE_CFG: begin
                frontend_enable = 1'b0;
                row_inject_enable = 1'b0;
                scheduler_enable = 1'b0;
                sa_enable = 1'b0;
                sa_compute_enable = 1'b0;
                output_window_valid = 1'b0;
            end
            
            WEIGHT_MAP: begin
                frontend_enable         = 1'b1;
                frontend_accept_enable  = 1'b1;
                row_inject_enable       = 1'b1;
                row_inject_mode         = 1'b0;
                if (!fifo_full)
                    fifo_write_enable = 1'b1;
                    
                scheduler_enable        = 1'b1;
                scheduler_weight_mode   = 1'b1;
                sa_enable               = 1'b1;sa_weight_load_enable   = 1'b1;// load weights into PE registers
                sa_compute_enable       = 1'b0;// no compute yet

            end
            
            ACT_STREAM_COMPUTE: begin
                frontend_enable         = 1'b1;
                frontend_accept_enable  = 1'b1;
                row_inject_enable       = 1'b1; row_inject_mode         = 1'b1;// 1 = activation mode
                if (!fifo_full)
                    fifo_write_enable = 1'b1;

                if (!fifo_empty)
                    fifo_read_enable = 1'b1;
                scheduler_enable            = 1'b1;
                scheduler_activation_mode   = 1'b1;
                sa_enable               = 1'b1;
                sa_compute_enable       = 1'b1;// computation active

            end
            
            DRAIN_WRITEBACK: begin
                frontend_enable         = 1'b0;
                row_inject_enable       = 1'b0;
                sa_enable                   = 1'b1;
                sa_compute_enable           = 1'b1;
                sa_pipeline_drain_enable    = 1'b1;
                output_accept_enable    = 1'b1;

                if (!output_buffer_full)
                    output_write_enable = 1'b1;

            end
            DONE: begin
                frontend_enable         = 1'b0;
                scheduler_enable        = 1'b0;
                sa_enable               = 1'b0;
                sa_compute_enable       = 1'b0;
                output_window_valid     = 1'b1;

            end
            
            ERROR: begin
            
                frontend_enable         = 1'b0;
                row_inject_enable       = 1'b0;
                fifo_flush              = 1'b1;
                scheduler_enable        = 1'b0;
                sa_enable               = 1'b0;
                sa_compute_enable       = 1'b0;
                frontend_flush          = 1'b1;

            end

        endcase

    end
    
    assign done  = (current_state == DONE);
    assign error = (current_state == ERROR);
    
    assign irq = done | error;
    assign state = current_state;
    assign weight_count_out = weight_count;
    assign act_count_out    = act_count;
    assign result_count_out = result_count;

endmodule
