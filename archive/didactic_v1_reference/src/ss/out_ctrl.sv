module output_controller #(
  parameter int unsigned NUM_COLS = 4,
  parameter int unsigned DATA_W   = 32,
  parameter int unsigned ADDR_W   = 16
)(
  // Global
  input  logic                clk,
  input  logic                rst_n,

  // Systolic array column outputs
  input  logic [DATA_W-1:0]   col_data  [NUM_COLS],
  input  logic                col_valid [NUM_COLS],

  // Output matrix buffer write port
  output logic                buf_wr_en,
  output logic [ADDR_W-1:0]   buf_wr_addr,
  output logic [DATA_W-1:0]   buf_wr_data,
  input  logic                buf_wr_ready,

  // Control/status from top controller
  input  logic                start,
  input  logic [ADDR_W-1:0]   base_addr,
  input  logic [ADDR_W-1:0]   col_stride,
  input  logic [3:0]          matrix_cols,
  output logic                done,
  output logic                overflow
);

  // TODO: implementation

endmodule