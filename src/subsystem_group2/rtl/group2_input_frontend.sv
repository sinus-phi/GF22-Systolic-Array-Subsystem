`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// Packed APB-word to SA-vector frontend.
//
// This block has no transaction FSM.  group2_sa_ctrl owns the global state:
// this block only unpacks signed elements, fills one ARRAY_HEIGHT vector,
// and emits one SA push pulse when the vector is full.
//
// Firmware writes packed APB words.  This block turns them into signed 32-bit
// lanes so the PE datapath can stay precision-agnostic.
//-----------------------------------------------------------------------------

module group2_input_frontend #(
    parameter int DATA_WIDTH = 32,
    parameter int ARRAY_HEIGHT = 8,
    parameter int ARRAY_WIDTH = 8,
    localparam int BUFF_CNTR_WIDTH = $clog2(ARRAY_HEIGHT + 1)
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         clear_i,

    input  logic                         weight_start_i,
    input  logic                         activation_start_i,
    input  logic [2:0]                   phase_i,
    input  logic [1:0]                   weight_precision_i,
    input  logic [1:0]                   activation_precision_i,
    input  logic [31:0]                  tile_k_i,
    input  logic [31:0]                  word_i,
    input  logic                         weight_word_valid_i,
    input  logic                         activation_word_valid_i,

    output logic                         vector_valid_o,
    output logic [ARRAY_HEIGHT*DATA_WIDTH-1:0] vector_data_o,
    output logic [ARRAY_WIDTH-1:0]       sa_load_o
);

  import group2_pkg::*;

  localparam logic [1:0] DTYPE_INT4  = 2'd0;
  localparam logic [1:0] DTYPE_INT8  = 2'd1;
  localparam logic [1:0] DTYPE_INT16 = 2'd2;
  localparam logic [BUFF_CNTR_WIDTH-1:0] FULL_VECTOR_ELEMS = ARRAY_HEIGHT;

  logic [BUFF_CNTR_WIDTH-1:0] fill_count_q;
  logic [$clog2(ARRAY_WIDTH+1)-1:0] weight_vec_idx_q;
  logic [DATA_WIDTH-1:0] input_buffer_q [0:ARRAY_HEIGHT-1];
  logic [DATA_WIDTH-1:0] decoded_elem [0:7];
  logic [3:0] elems_this_word;
  logic [BUFF_CNTR_WIDTH-1:0] active_elem_count;
  logic [BUFF_CNTR_WIDTH:0] fill_after_word;
  logic [1:0] active_precision;
  logic word_valid;
  logic weight_mode;

  integer idx;
  integer dec_idx;
  integer elem_idx;

  assign weight_mode      = (phase_i == PH_LOAD_WEIGHTS);
  assign word_valid       = weight_word_valid_i | activation_word_valid_i;
  // Weight and activation streams can use different precisions.  The accepted
  // word type decides which unpack rule is used for the current APB word.
  assign active_precision = weight_word_valid_i ? weight_precision_i : activation_precision_i;
  assign fill_after_word  = {1'b0, fill_count_q} +
                            {1'b0, elems_this_word[BUFF_CNTR_WIDTH-1:0]};

  always_comb begin
    // tile_k controls how many K lanes are meaningful in the current vector.
    // The physical SA still receives ARRAY_HEIGHT lanes; lanes >= tile_k are
    // padded with zero when the vector is emitted.  Invalid/zero tile_k values
    // are treated as full width here; the address decoder rejects invalid CONFIG
    // before a transaction can start.
    active_elem_count = FULL_VECTOR_ELEMS;
    if ((tile_k_i > 32'd0) && (tile_k_i < 32'(ARRAY_HEIGHT))) begin
      active_elem_count = tile_k_i[BUFF_CNTR_WIDTH-1:0];
    end
  end

  always_comb begin
    elems_this_word = 4'd1;
    for (dec_idx = 0; dec_idx < 8; dec_idx = dec_idx + 1) begin
      decoded_elem[dec_idx] = '0;
    end

    unique case (active_precision)
      DTYPE_INT4: begin
        elems_this_word = 4'd8;
        for (dec_idx = 0; dec_idx < 8; dec_idx = dec_idx + 1) begin
          // Nibble bit 3 is the sign bit.  Sign extension here is the key
          // difference from the earlier zero-extension-friendly dummy path.
          decoded_elem[dec_idx] = {{(DATA_WIDTH-4){word_i[(4*dec_idx)+3]}},
                                   word_i[4*dec_idx +: 4]};
        end
      end

      DTYPE_INT8: begin
        elems_this_word = 4'd4;
        for (dec_idx = 0; dec_idx < 4; dec_idx = dec_idx + 1) begin
          // Byte bit 7 is the sign bit.
          decoded_elem[dec_idx] = {{(DATA_WIDTH-8){word_i[(8*dec_idx)+7]}},
                                   word_i[8*dec_idx +: 8]};
        end
      end

      DTYPE_INT16: begin
        elems_this_word = 4'd2;
        for (dec_idx = 0; dec_idx < 2; dec_idx = dec_idx + 1) begin
          // Halfword bit 15 is the sign bit.
          decoded_elem[dec_idx] = {{(DATA_WIDTH-16){word_i[(16*dec_idx)+15]}},
                                   word_i[16*dec_idx +: 16]};
        end
      end

      default: begin
        elems_this_word = 4'd1;
        decoded_elem[0] = word_i;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_count_q     <= '0;
      weight_vec_idx_q <= '0;
      vector_valid_o   <= 1'b0;
      vector_data_o    <= '0;
      sa_load_o        <= '0;
      for (idx = 0; idx < ARRAY_HEIGHT; idx = idx + 1) begin
        input_buffer_q[idx] <= '0;
      end
    end else begin
      vector_valid_o <= 1'b0;
      sa_load_o      <= '0;

      if (clear_i || weight_start_i || activation_start_i) begin
        // Start each logical stream on a clean vector boundary.  Firmware is
        // responsible for starting every new weight column or activation row at
        // a new APB word.  If tile_k does not consume all elements in the final
        // word, the unused high elements are ignored rather than carried into
        // the next vector.
        fill_count_q <= '0;
        if (weight_start_i) begin
          weight_vec_idx_q <= '0;
        end
      end else if (word_valid) begin
        for (elem_idx = 0; elem_idx < 8; elem_idx = elem_idx + 1) begin
          if ((elem_idx < elems_this_word) &&
              ((fill_count_q + elem_idx) < active_elem_count)) begin
            input_buffer_q[fill_count_q + elem_idx] <= decoded_elem[elem_idx];
          end
        end

        if (fill_after_word >= {1'b0, active_elem_count}) begin
          // The current APB word completed the tile_k-wide logical vector.
          // Older elements come from input_buffer_q; the tail comes directly
          // from decoded_elem.  Remaining physical lanes are zero-padded.
          for (elem_idx = 0; elem_idx < ARRAY_HEIGHT; elem_idx = elem_idx + 1) begin
            if (elem_idx < active_elem_count) begin
              if (elem_idx >= fill_count_q) begin
                vector_data_o[elem_idx*DATA_WIDTH +: DATA_WIDTH] <=
                    decoded_elem[elem_idx - fill_count_q];
              end else begin
                vector_data_o[elem_idx*DATA_WIDTH +: DATA_WIDTH] <=
                    input_buffer_q[elem_idx];
              end
            end else begin
              vector_data_o[elem_idx*DATA_WIDTH +: DATA_WIDTH] <=
                  {DATA_WIDTH{1'b0}};
            end
          end

          vector_valid_o <= 1'b1;
          fill_count_q   <= '0;

          if (weight_mode && (weight_vec_idx_q < ARRAY_WIDTH)) begin
            // Firmware streams columns in output order. Map the first weight
            // vector to lane 0 so compact APB output reads lane 0..N-1.
            sa_load_o[weight_vec_idx_q] <= 1'b1;
            weight_vec_idx_q <= weight_vec_idx_q + 1'b1;
          end
        end else begin
          fill_count_q <= fill_after_word[BUFF_CNTR_WIDTH-1:0];
        end
      end
    end
  end

endmodule
