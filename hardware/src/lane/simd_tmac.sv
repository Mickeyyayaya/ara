`timescale 1ns/1ps

module simd_tmac import ara_pkg::*; import rvv_pkg::*; #(
    parameter  int    unsigned NumPipeRegs  = 2,  // Increased pipeline depth to optimize Fmax
    parameter  int    unsigned GroupSize    = 4,
    localparam int    unsigned DataWidth    = $bits(elen_t),
    localparam int    unsigned StrbWidth    = DataWidth/8,
    localparam type            strb_t       = logic [DataWidth/8-1:0],
    localparam int    unsigned LutSize      = 2**GroupSize,
    localparam int    unsigned NumGroups    = (8 + GroupSize - 1) / GroupSize
  ) (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  elen_t      operand_a_i, // Activation (A)
    input  elen_t      operand_b_i, // Weight (W)
    input  elen_t      operand_c_i,
    input  strb_t      mask_i,
    input  ara_op_e    op_i,
    input  vew_e       vew_i,
    output elen_t      result_o,
    output strb_t      mask_o,
    output vxsat_t     vxsat_o,
    input  vxrm_t      vxrm_i,
    input  logic       valid_i,
    output logic       ready_o,
    input  logic       ready_i,
    output logic       valid_o
  );

  typedef union packed {
    logic [0:0][63:0] w64;
    logic [1:0][31:0] w32;
    logic [3:0][15:0] w16;
    logic [7:0][ 7:0] w8;
  } tmac_operand_t;

  typedef logic signed [15:0] lut_entry_t;

  logic is_tmac_op;
  logic [3:0] weight_bits;
  assign vxsat_o = '0;

  always_comb begin : p_tmac_op_decode
    case (op_i)
      VTMUL1: begin is_tmac_op = 1'b1; weight_bits = 4'd1; end
      VTMUL2: begin is_tmac_op = 1'b1; weight_bits = 4'd2; end
      VTMUL3: begin is_tmac_op = 1'b1; weight_bits = 4'd3; end
      VTMUL4: begin is_tmac_op = 1'b1; weight_bits = 4'd4; end
      default: begin is_tmac_op = 1'b0; weight_bits = 4'd0; end
    endcase
  end

  // Pipeline Stall Logic (Basic backpressure control)
  logic stall;
  assign stall   = ~ready_i && valid_o;
  assign ready_o = ~stall;
  logic pipe_en;
  assign pipe_en = ~stall;

  // ==========================================
  //  Stage 1: Input Capture
  // ==========================================
  tmac_operand_t opa_s1, opb_s1;
  strb_t         mask_s1;
  vew_e          vew_s1;
  logic          valid_s1, is_tmac_op_s1;
  logic [3:0]    weight_bits_s1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_s1 <= 1'b0;
    end else if (pipe_en) begin
      valid_s1       <= valid_i;
      opa_s1         <= tmac_operand_t'(operand_a_i);
      opb_s1         <= tmac_operand_t'(operand_b_i);
      mask_s1        <= mask_i;
      vew_s1         <= vew_i;
      is_tmac_op_s1  <= is_tmac_op;
      weight_bits_s1 <= weight_bits;
    end
  end

  // ==========================================
  //  Stage 2: Optimized LUT Generation (Shared Adder Tree)
  // ==========================================
  lut_entry_t    lut_memory [NumGroups-1:0][LutSize-1:0];
  lut_entry_t    lut_next   [NumGroups-1:0][LutSize-1:0];
  
  tmac_operand_t opb_s2;
  strb_t         mask_s2;
  vew_e          vew_s2;
  logic          valid_s2, is_tmac_op_s2;
  logic [3:0]    weight_bits_s2;

  // Incremental (DP) LUT generation optimization:
  // Reduces complexity from O(N * 2^N) to O(2^N) adders by reusing previously computed values.
  always_comb begin
    for (int g = 0; g < NumGroups; g++) begin
      lut_next[g][0] = '0; // Base case: value for zero combination is zero
      for (int i = 0; i < GroupSize; i++) begin
        automatic int bit_val = 1 << i;
        for (int j = 0; j < bit_val; j++) begin
          // The new combination equals the existing combination plus the newly appended element.
          // This forces the synthesis tool to reuse the prior adder stage outputs, reducing area.
          lut_next[g][bit_val + j] = lut_next[g][j] + $signed(opa_s1.w8[g * GroupSize + i]);
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_s2 <= 1'b0;
    end else if (pipe_en) begin
      valid_s2       <= valid_s1;
      opb_s2         <= opb_s1;
      mask_s2        <= mask_s1;
      vew_s2         <= vew_s1;
      is_tmac_op_s2  <= is_tmac_op_s1;
      weight_bits_s2 <= weight_bits_s1;
      
      if (is_tmac_op_s1) begin
        lut_memory <= lut_next; // Store the optimized LUT
      end
    end
  end

  // ==========================================
  //  Stage 3: Pipelined LUT Lookup (Critical Path Break)
  // ==========================================
  // Performs the table lookup and registers the retrieved data to isolate MUX propagation delay from accumulation.
  logic signed [15:0] looked_up_vals [3:0][NumGroups]; // Max 4 bits for weights
  
  strb_t         mask_s3;
  logic          valid_s3, is_tmac_op_s3;
  logic [3:0]    weight_bits_s3;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_s3 <= 1'b0;
    end else if (pipe_en) begin
      valid_s3       <= valid_s2;
      mask_s3        <= mask_s2;
      is_tmac_op_s3  <= is_tmac_op_s2;
      weight_bits_s3 <= weight_bits_s2;

      // Execute large MUX lookup array and register results
      if (is_tmac_op_s2) begin
        for (int bit_idx = 0; bit_idx < 4; bit_idx++) begin // Unroll up to maximum supported weight bits
          for (int group_idx = 0; group_idx < NumGroups; group_idx++) begin
            automatic logic [GroupSize-1:0] weight_pattern = '0;
            for (int g = 0; g < GroupSize; g++) begin
              weight_pattern[g] = opb_s2.w8[group_idx * GroupSize + g][bit_idx];
            end
            looked_up_vals[bit_idx][group_idx] <= lut_memory[group_idx][weight_pattern];
          end
        end
      end
    end
  end

  // ==========================================
  //  Stage 4: Accumulate & Output
  // ==========================================
  elen_t result_comb;

  always_comb begin : p_tmac_accumulate
    logic signed [DataWidth-1:0] total_accumulated;
    logic signed [DataWidth-1:0] bit_plane_sum;
    
    total_accumulated = '0;

    if (is_tmac_op_s3) begin
      // MUX delay is isolated by the stage 3 boundary; perform clean shift-and-add logic here
      for (int bit_idx = 0; bit_idx < weight_bits_s3; bit_idx++) begin
        bit_plane_sum = '0;
        for (int group_idx = 0; group_idx < NumGroups; group_idx++) begin
           bit_plane_sum += $signed(looked_up_vals[bit_idx][group_idx]);
        end
        total_accumulated += (bit_plane_sum << bit_idx);
      end
    end
    result_comb = elen_t'(total_accumulated);
  end

  assign result_o = result_comb;
  assign mask_o   = mask_s3;
  assign valid_o  = valid_s3;

endmodule : simd_tmac