// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description:
// Enhanced high-performance SIMD PE for Ara.
// - Custom ISA Packing: Extracts four 2-bit weights from a single 8-bit byte.
// - Input Stationary Dataflow: 1 Activation broadcasts to 4 Weights (W2A8)
// - 128-bit Widened Output: 4 independent 32-bit accumulated results
// - 3-stage pipeline (S0: Decode, S1: Multiply, S2: Accumulate)

module simd_pe import ara_pkg::*; import rvv_pkg::*; #(
    parameter  int    unsigned NumLanes     = 16,
    parameter  int    unsigned A_BITS       = 8,
    parameter  int    unsigned W_BITS       = 2,
    parameter  int    unsigned P_BITS       = 32,
    parameter  int    unsigned BufferDepth  = 4,
    parameter  bit             UsePragmatic = 1'b0,
    localparam int    unsigned DataWidth    = $bits(elen_t),
    localparam int    unsigned StrbWidth    = DataWidth/8
  ) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  elen_t                  operand_a_i,
    input  elen_t                  operand_b_i,
    input  elen_t                  operand_c_i,
    input  logic [StrbWidth-1:0]   mask_i,
    input  ara_op_e                op_i,
    input  vew_e                   vew_i,
    output logic [3:0][P_BITS-1:0] result_o,
    output logic [StrbWidth-1:0]   mask_o,
    output vxsat_t                 vxsat_o,
    input  vxrm_t                  vxrm_i,
    input  logic                   valid_i,
    output logic                   ready_o,
    input  logic                   ready_i,
    output logic                   valid_o
  );

`include "common_cells/registers.svh"

  // Packing definition: 
  // Each lane is allocated 8 bits. 16 lanes map to a 128-bit elen_t vector.
  typedef union packed {
    logic [NumLanes-1:0][7:0] w8; 
  } pe_operand_t;

  typedef struct packed {
    pe_operand_t opa;
    pe_operand_t opb;
    logic [StrbWidth-1:0] mask;
  } operand_buffer_entry_t;

  assign vxsat_o = '0;

  // ==========================================
  //  Operand Buffer (Input FIFO)      
  // ==========================================
  operand_buffer_entry_t [BufferDepth-1:0] operand_buffer;
  logic [$clog2(BufferDepth):0] buffer_count;
  logic buffer_full, buffer_empty;
  logic [$clog2(BufferDepth)-1:0] wr_ptr, rd_ptr;

  logic valid_s0_q, valid_s1_q, valid_s2_q; 
  logic s2_ready, s1_ready; 
  
  assign s2_ready = ready_i || ~valid_s2_q; 
  assign s1_ready = s2_ready || ~valid_s1_q; 

  // ==========================================
  //  Pipeline Stage 0: Decode & Buffer
  // ==========================================
  pe_operand_t          opa_s0_q;
  pe_operand_t          opb_s0_q;
  logic [StrbWidth-1:0] mask_s0_q;
  logic                 s0_read_buffer;

  assign s0_read_buffer = ~buffer_empty && (s1_ready || ~valid_s0_q);
  assign buffer_full = (buffer_count == BufferDepth);
  assign buffer_empty = (buffer_count == 0);
  assign ready_o = ~buffer_full;
  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr <= '0; rd_ptr <= '0; buffer_count <= '0;
    end else begin
      if (valid_i && ~buffer_full) begin
        operand_buffer[wr_ptr].opa <= pe_operand_t'(operand_a_i);
        operand_buffer[wr_ptr].opb <= pe_operand_t'(operand_b_i);
        operand_buffer[wr_ptr].mask <= mask_i;
        wr_ptr <= (wr_ptr == BufferDepth-1) ? '0 : wr_ptr + 1;
      end
      if (s0_read_buffer && ~buffer_empty) begin
        rd_ptr <= (rd_ptr == BufferDepth-1) ? '0 : rd_ptr + 1;
      end
      case ({valid_i && ~buffer_full, s0_read_buffer && ~buffer_empty})
        2'b10: buffer_count <= buffer_count + 1;
        2'b01: buffer_count <= buffer_count - 1;
        default: buffer_count <= buffer_count;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) valid_s0_q <= 1'b0;
    else begin
      if (s0_read_buffer) valid_s0_q <= 1'b1;
      else if (s1_ready && valid_s0_q) valid_s0_q <= 1'b0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (s0_read_buffer) begin 
      opa_s0_q <= operand_buffer[rd_ptr].opa;
      opb_s0_q <= operand_buffer[rd_ptr].opb;
      mask_s0_q <= operand_buffer[rd_ptr].mask;
    end
  end

  // ==========================================
  //  Pipeline Stage 1: Multiply (Hardware Unpacking)
  // ==========================================
  logic [A_BITS-1:0]        A_in[0:NumLanes-1][0:3];
  logic [W_BITS-1:0]        W_in[0:NumLanes-1][0:3];
  logic                     is_a_zero[0:NumLanes-1][0:3];
  logic                     mul_enable[0:NumLanes-1][0:3];
  
  logic signed [P_BITS-1:0] p_sub[0:NumLanes-1][0:3]; 
  logic signed [P_BITS-1:0] p_sub_s1_q[0:NumLanes-1][0:3]; 
  logic [StrbWidth-1:0]     mask_s1_q;

  always_comb begin : p_extract_pairs
    for (int i = 0; i < NumLanes; i++) begin
      for (int k = 0; k < 4; k++) begin
        // Broadcast a single 8-bit activation to 4 multipliers
        A_in[i][k] = opa_s0_q.w8[i];
        
        // Extract four sub-byte 2-bit weights from the 8-bit space to eliminate padding
        W_in[i][k] = opb_s0_q.w8[i][k*W_BITS +: W_BITS];

        is_a_zero[i][k] = (A_in[i][k] == '0);
        mul_enable[i][k] = ~is_a_zero[i][k]; 
      end
    end
  end

  generate
    for (genvar i = 0; i < NumLanes; i++) begin : lane_gen
      for (genvar k = 0; k < 4; k++) begin : sub_gen
        logic signed [P_BITS-1:0] p_raw; 
        mul_standard_pe #(
          .A_BITS(A_BITS), .W_BITS(W_BITS), .P_BITS(P_BITS)
        ) mul_inst (
          .a(A_in[i][k]), .b(W_in[i][k]), .p(p_raw),
          .clk(clk_i), .rst_n(rst_ni), .clear(1'b0),
          .in_valid(1'b1), .out_valid()
        );
        assign p_sub[i][k] = mul_enable[i][k] ? p_raw : '0;
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) valid_s1_q <= 1'b0;
    else if (s1_ready) valid_s1_q <= valid_s0_q; 
  end
  
  always_ff @(posedge clk_i) begin
    if (s1_ready && valid_s0_q) begin 
      p_sub_s1_q <= p_sub; 
      mask_s1_q  <= mask_s0_q;
    end
  end

  // ==========================================
  //  Pipeline Stage 2: Accumulate 
  // ==========================================
  logic signed [3:0][P_BITS-1:0] accumulated_sum; 
  logic signed [3:0][P_BITS-1:0] accumulated_sum_s2_q;
  logic [StrbWidth-1:0]     mask_s2_q;

  always_comb begin : p_accumulate
    for (int k = 0; k < 4; k++) begin
      accumulated_sum[k] = '0;
      for (int i = 0; i < NumLanes; i++) begin
        accumulated_sum[k] = accumulated_sum[k] + p_sub_s1_q[i][k];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) valid_s2_q <= 1'b0;
    else if (s2_ready) valid_s2_q <= valid_s1_q; 
  end

  always_ff @(posedge clk_i) begin
    if (s2_ready && valid_s1_q) begin 
      accumulated_sum_s2_q <= accumulated_sum;
      mask_s2_q            <= mask_s1_q;
    end
  end
  
  // ==========================================
  //  Pipeline Stage 3: Writeback   
  // ==========================================
  assign result_o = accumulated_sum_s2_q;
  assign mask_o   = mask_s2_q;
  assign valid_o  = valid_s2_q;

endmodule : simd_pe

module mul_standard_pe #(
  parameter int A_BITS = 8, 
  parameter int W_BITS = 2, 
  parameter int P_BITS = 32
) (
  input  signed [A_BITS-1:0] a, 
  input         [W_BITS-1:0] b, 
  output signed [P_BITS-1:0] p,
  input clk, rst_n, clear, in_valid, 
  output logic out_valid
);
  // Calculate minimal required internal bit-width (8 + 2 = 10 bits) to optimize area
  localparam int INNER_BITS = A_BITS + W_BITS; 
  
  logic signed [INNER_BITS-1:0] a_ext_inner, a_shifted, a_times_three, raw_result;

  // 1. Sign-extend input to the 10-bit internal boundary to minimize adder and MUX area
  assign a_ext_inner = {{(INNER_BITS-A_BITS){a[A_BITS-1]}}, a};
  
  // 2. Internal 10-bit shift and add operations
  assign a_shifted = a_ext_inner << 1;
  assign a_times_three = a_ext_inner + a_shifted;
  
  // 3. Internal 10-bit 4-to-1 MUX
  always_comb begin
    case (b)
      2'b00: raw_result = '0;              
      2'b01: raw_result = a_ext_inner;      
      2'b10: raw_result = a_shifted;       
      2'b11: raw_result = a_times_three;   
    endcase
  end

  // 4. Final 32-bit sign-extension for downstream accumulation
  assign p = {{(P_BITS-INNER_BITS){raw_result[INNER_BITS-1]}}, raw_result};
  
  assign out_valid = 1'b1;
endmodule