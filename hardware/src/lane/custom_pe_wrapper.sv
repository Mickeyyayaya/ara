// Custom PE Wrapper for Ara integration
module custom_pe_wrapper import ara_pkg::*; import rvv_pkg::*; import cf_math_pkg::idx_width; #(
    parameter int unsigned NrLanes = 4,
    parameter int unsigned VLEN = 0,
    parameter type vaddr_t = logic,
    parameter type vfu_operation_t = logic,
    // Dependant parameters
    localparam int unsigned DataWidth = $bits(elen_t),
    localparam int unsigned StrbWidth = DataWidth/8,
    localparam type strb_t = logic [DataWidth/8-1:0],
    localparam type vlen_t = logic[$clog2(VLEN+1)-1:0]
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic[idx_width(NrLanes)-1:0] lane_id_i,
    
    // Interface with the lane sequencer
    input  vfu_operation_t               vfu_operation_i,
    input  logic                         vfu_operation_valid_i,
    output logic                         custom_pe_ready_o,
    output logic           [NrVInsn-1:0] custom_pe_vinsn_done_o,
    
    // Interface with the operand queues
    input  elen_t          [1:0]         custom_pe_operand_i, // Activation, Weight
    input  logic           [1:0]         custom_pe_operand_valid_i,
    output logic           [1:0]         custom_pe_operand_ready_o,
    
    // Interface with the vector register file
    output logic                         custom_pe_result_req_o,
    output vid_t                         custom_pe_result_id_o,
    output vaddr_t                       custom_pe_result_addr_o,
    output elen_t                        custom_pe_result_wdata_o,
    output strb_t                        custom_pe_result_be_o,
    input  logic                         custom_pe_result_gnt_i,
    
    // Interface with the Mask unit
    input  strb_t                        mask_i,
    input  logic                         mask_valid_i,
    output logic                         mask_ready_o
);

////////////////////////////////
//  Vector instruction queue  //
////////////////////////////////

localparam VInsnQueueDepth = CustomPEInsnQueueDepth;

struct packed {
  vfu_operation_t [VInsnQueueDepth-1:0] vinsn;
  logic [idx_width(VInsnQueueDepth)-1:0] accept_pnt;
  logic [idx_width(VInsnQueueDepth)-1:0] issue_pnt;
  logic [idx_width(VInsnQueueDepth)-1:0] processing_pnt;
  logic [idx_width(VInsnQueueDepth)-1:0] commit_pnt;
  logic [idx_width(VInsnQueueDepth):0] issue_cnt;
  logic [idx_width(VInsnQueueDepth):0] processing_cnt;
  logic [idx_width(VInsnQueueDepth):0] commit_cnt;
} vinsn_queue_d, vinsn_queue_q;

logic vinsn_queue_full;
assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);

vfu_operation_t vinsn_issue_q, vinsn_processing_q, vinsn_commit;
logic vinsn_issue_q_valid, vinsn_processing_q_valid, vinsn_commit_valid;

assign vinsn_issue_q = vinsn_queue_q.vinsn[vinsn_queue_q.issue_pnt];
assign vinsn_issue_q_valid = (vinsn_queue_q.issue_cnt != '0);
assign vinsn_processing_q = vinsn_queue_q.vinsn[vinsn_queue_q.processing_pnt];
assign vinsn_processing_q_valid = (vinsn_queue_q.processing_cnt != '0);
assign vinsn_commit = vinsn_queue_q.vinsn[vinsn_queue_q.commit_pnt];
assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);

////////////////////
//  Result queue  //
////////////////////

localparam int unsigned ResultQueueDepth = 2;

typedef struct packed {
  vid_t id;
  vaddr_t addr;
  elen_t wdata;
  strb_t be;
} payload_t;

payload_t [ResultQueueDepth-1:0] result_queue_d, result_queue_q;
logic [ResultQueueDepth-1:0] result_queue_valid_d, result_queue_valid_q;
logic [idx_width(ResultQueueDepth)-1:0] result_queue_write_pnt_d, result_queue_write_pnt_q;
logic [idx_width(ResultQueueDepth)-1:0] result_queue_read_pnt_d, result_queue_read_pnt_q;
logic [idx_width(ResultQueueDepth):0] result_queue_cnt_d, result_queue_cnt_q;

logic result_queue_full;
assign result_queue_full = (result_queue_cnt_q == ResultQueueDepth);

///////////////////
//  PE Instance  //
///////////////////

// PE control signals
logic pe_rst_n, pe_clk, pe_in_valid, pe_clear;
logic pe_out_valid;
logic signed [31:0] pe_output_value;

// PE data interface
logic [8 * 64 - 1:0] pe_activation;  // 8-bit x 64 pairs
logic [2 * 64 - 1:0] pe_weight;      // 2-bit x 64 pairs

// PE實例化 - SystemVerilog版本的PE模組
PE #(
  .A_BITS(8),
  .W_BITS(2),
  .P_BITS(32),
  .LANES(4),
  .NUM_PAIRS(64)
) i_custom_pe (
  .rst_n(pe_rst_n),
  .clk(pe_clk), 
  .in_valid(pe_in_valid),
  .clear(pe_clear),
  .Activation(pe_activation),
  .Weight(pe_weight),
  .out_valid(pe_out_valid),
  .output_value(pe_output_value)
);

// Control logic
vlen_t issue_cnt_d, issue_cnt_q;
vlen_t commit_cnt_d, commit_cnt_q;

logic operands_valid;
logic [1:0] operands_ready;

// Assign PE control signals
assign pe_rst_n = rst_ni;
assign pe_clk = clk_i;
assign pe_clear = 1'b0; // Can be controlled based on instruction

always_comb begin: p_custom_pe_control
  // Maintain state
  vinsn_queue_d = vinsn_queue_q;
  result_queue_d = result_queue_q;
  result_queue_valid_d = result_queue_valid_q;
  result_queue_write_pnt_d = result_queue_write_pnt_q;
  result_queue_read_pnt_d = result_queue_read_pnt_q;
  result_queue_cnt_d = result_queue_cnt_q;
  
  issue_cnt_d = issue_cnt_q;
  commit_cnt_d = commit_cnt_q;
  
  // Default outputs
  custom_pe_ready_o = !vinsn_queue_full;
  custom_pe_vinsn_done_o = '0;
  custom_pe_operand_ready_o = '0;
  mask_ready_o = 1'b0;
  
  // PE control
  pe_in_valid = 1'b0;
  pe_activation = '0;
  pe_weight = '0;
  
  // Check if operands are valid
  operands_valid = custom_pe_operand_valid_i[0] && custom_pe_operand_valid_i[1] && 
                   (mask_valid_i || vinsn_issue_q.vm);
  operands_ready = {vinsn_issue_q.use_vs2, vinsn_issue_q.use_vs1};
  
  ///////////////////////////
  //  Issue Instructions  //
  ///////////////////////////
  
  if (operands_valid && vinsn_issue_q_valid && issue_cnt_q != '0) begin
    // Convert 64-bit operands to PE format
    pe_activation = {{(8*64-64){1'b0}}, custom_pe_operand_i[0]};  // Activation
    pe_weight = {{(2*64-64){1'b0}}, custom_pe_operand_i[1]};     // Weight
    pe_in_valid = 1'b1;
    
    // Acknowledge operands
    custom_pe_operand_ready_o = operands_ready;
    mask_ready_o = ~vinsn_issue_q.vm;
    
    // Update issue counter
    if (vlen_t'(64) > issue_cnt_q) begin
      issue_cnt_d = '0;
    end else begin
      issue_cnt_d = issue_cnt_q - vlen_t'(64);
    end
    
    // Finished issuing
    if (issue_cnt_d == '0) begin
      vinsn_queue_d.issue_cnt -= 1;
      if (vinsn_queue_q.issue_pnt == VInsnQueueDepth-1) 
        vinsn_queue_d.issue_pnt = '0;
      else 
        vinsn_queue_d.issue_pnt = vinsn_queue_q.issue_pnt + 1;
        
      if (vinsn_queue_d.issue_cnt != 0)
        issue_cnt_d = vinsn_queue_q.vinsn[vinsn_queue_d.issue_pnt].vl;
    end
  end
  
  ////////////////////////////
  //  Process PE Results    //
  ////////////////////////////
  
  if (pe_out_valid && !result_queue_full) begin
    // Store result in queue
    result_queue_d[result_queue_write_pnt_q].id = vinsn_processing_q.id;
    result_queue_d[result_queue_write_pnt_q].addr = vaddr(vinsn_processing_q.vd, NrLanes, VLEN);
    result_queue_d[result_queue_write_pnt_q].wdata = elen_t'(pe_output_value);
    result_queue_d[result_queue_write_pnt_q].be = {StrbWidth{1'b1}};
    result_queue_valid_d[result_queue_write_pnt_q] = 1'b1;
    
    // Update result queue pointers
    result_queue_cnt_d += 1;
    if (result_queue_write_pnt_q == ResultQueueDepth-1)
      result_queue_write_pnt_d = 0;
    else
      result_queue_write_pnt_d = result_queue_write_pnt_q + 1;
    
    // Update processing
    vinsn_queue_d.processing_cnt -= 1;
    if (vinsn_queue_q.processing_pnt == VInsnQueueDepth-1)
      vinsn_queue_d.processing_pnt = '0;
    else
      vinsn_queue_d.processing_pnt = vinsn_queue_q.processing_pnt + 1;
  end
  
  ///////////////////////////////
  //  Write results to VRF    //
  ///////////////////////////////
  
  custom_pe_result_req_o = result_queue_valid_q[result_queue_read_pnt_q];
  custom_pe_result_addr_o = result_queue_q[result_queue_read_pnt_q].addr;
  custom_pe_result_id_o = result_queue_q[result_queue_read_pnt_q].id;
  custom_pe_result_wdata_o = result_queue_q[result_queue_read_pnt_q].wdata;
  custom_pe_result_be_o = result_queue_q[result_queue_read_pnt_q].be;
  
  if (custom_pe_result_gnt_i) begin
    result_queue_valid_d[result_queue_read_pnt_q] = 1'b0;
    
    if (result_queue_read_pnt_q == ResultQueueDepth-1)
      result_queue_read_pnt_d = 0;
    else
      result_queue_read_pnt_d = result_queue_read_pnt_q + 1;
      
    result_queue_cnt_d -= 1;
    
    // Update commit counter
    if (commit_cnt_q < vlen_t'(64)) begin
      commit_cnt_d = '0;
    end else begin
      commit_cnt_d = commit_cnt_q - vlen_t'(64);
    end
  end
  
  // Finished committing
  if (vinsn_commit_valid && commit_cnt_d == '0) begin
    custom_pe_vinsn_done_o[vinsn_commit.id] = 1'b1;
    
    vinsn_queue_d.commit_cnt -= 1;
    if (vinsn_queue_d.commit_pnt == VInsnQueueDepth-1)
      vinsn_queue_d.commit_pnt = '0;
    else
      vinsn_queue_d.commit_pnt += 1;
      
    if (vinsn_queue_d.commit_cnt != '0)
      commit_cnt_d = vinsn_queue_q.vinsn[vinsn_queue_d.commit_pnt].vl;
  end
  
  //////////////////////////////
  //  Accept new instruction  //
  //////////////////////////////
  
  if (!vinsn_queue_full && vfu_operation_valid_i && 
      vfu_operation_i.vfu == VFU_CustomPE) begin
    vinsn_queue_d.vinsn[vinsn_queue_q.accept_pnt] = vfu_operation_i;
    
    // Initialize counters
    if (vinsn_queue_d.issue_cnt == '0) 
      issue_cnt_d = vfu_operation_i.vl;
    if (vinsn_queue_d.processing_cnt == '0) 
      // Processing counter is not used in this simple version
      ;
    if (vinsn_queue_d.commit_cnt == '0) 
      commit_cnt_d = vfu_operation_i.vl;
      
    // Update queue pointers
    vinsn_queue_d.accept_pnt += 1;
    vinsn_queue_d.issue_cnt += 1;
    vinsn_queue_d.processing_cnt += 1;
    vinsn_queue_d.commit_cnt += 1;
  end
end

// Sequential logic
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    vinsn_queue_q <= '0;
    result_queue_q <= '0;
    result_queue_valid_q <= '0;
    result_queue_write_pnt_q <= '0;
    result_queue_read_pnt_q <= '0;
    result_queue_cnt_q <= '0;
    issue_cnt_q <= '0;
    commit_cnt_q <= '0;
  end else begin
    vinsn_queue_q <= vinsn_queue_d;
    result_queue_q <= result_queue_d;
    result_queue_valid_q <= result_queue_valid_d;
    result_queue_write_pnt_q <= result_queue_write_pnt_d;
    result_queue_read_pnt_q <= result_queue_read_pnt_d;
    result_queue_cnt_q <= result_queue_cnt_d;
    issue_cnt_q <= issue_cnt_d;
    commit_cnt_q <= commit_cnt_d;
  end
end

endmodule