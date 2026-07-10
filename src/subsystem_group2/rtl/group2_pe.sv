`timescale 1ns/1ps

module group2_pe (
    input  logic               clk_i,
    input  logic               rst_ni,
    input  logic               clear_i,
    input  logic               advance_i,

    input  logic               weight_load_i,
    input  logic               weight_bank_i,
    input  logic signed [15:0] weight_i,

    input  logic               data_valid_i,
    input  logic               data_bank_i,
    input  logic signed [15:0] data_i,
    input  logic signed [15:0] sum_i,

    output logic               sum_valid_o,
    output logic signed [15:0] sum_o
);

  logic signed [15:0] weight_q [0:1];
  logic signed [15:0] product_q;
  logic               product_valid_q;
  logic signed [31:0] product_full;

  always_comb begin
    product_full = data_i * weight_q[data_bank_i];
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      weight_q[0]    <= '0;
      weight_q[1]    <= '0;
      product_q      <= '0;
      product_valid_q <= 1'b0;
      sum_o           <= '0;
      sum_valid_o     <= 1'b0;
    end else begin
      if (weight_load_i) begin
        weight_q[weight_bank_i] <= weight_i;
      end

      if (clear_i) begin
        product_q       <= '0;
        product_valid_q <= 1'b0;
        sum_o            <= '0;
        sum_valid_o      <= 1'b0;
      end else if (advance_i) begin
        product_valid_q <= data_valid_i;
        sum_valid_o     <= product_valid_q;

        if (data_valid_i) begin
          product_q <= product_full[15:0];
        end
        if (product_valid_q) begin
          sum_o <= product_q + sum_i;
        end
      end
    end
  end

endmodule
