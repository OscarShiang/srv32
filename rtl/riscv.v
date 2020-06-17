// Three pipeline stage RV32I RISCV processor
// Written by Kuoping Hsu, 2020, MIT license
module riscv (
    input                   clk,
    input                   resetb,

    input                   stall,
    output reg              exception,

    // interface of instruction RAM
    output                  imem_ready,
    input           [31: 0] imem_rdata,
    input                   imem_valid,
    output          [31: 0] imem_addr,
    
    // interface of data RAM
    output                  dmem_wready,
    output                  dmem_rready,
    input           [31: 0] dmem_rdata,
    input                   dmem_wvalid,
    input                   dmem_rvalid,
    output          [31: 0] dmem_waddr,
    output          [31: 0] dmem_raddr,
    output          [31: 0] dmem_wdata,
    output          [ 3: 0] dmem_wstrb
);

`include "opcode.vh"

    reg             [31: 0] if_pc;
    reg                     stall_r;

    wire            [31: 0] inst;
    reg                     flush;

    // register files
    reg             [31: 0] regs [31: 1];
    wire            [31: 0] reg_rdata1, reg_rdata2;

    reg             [31: 0] ex_pc;
    reg             [31: 0] ex_imm;
    reg                     ex_imm_sel;

    reg             [ 4: 0] ex_src1_sel;
    reg             [ 4: 0] ex_src2_sel;
    reg             [ 4: 0] ex_dst_sel;

    reg             [ 2: 0] ex_alu_op;
    reg                     ex_subtype;
    reg                     ex_memwr;
    reg                     ex_mem2reg;
    reg                     ex_alu;
    reg                     ex_csr;
    reg                     ex_lui;
    reg                     ex_auipc;
    reg                     ex_jal;
    reg                     ex_jalr;
    reg                     ex_branch;
    reg                     wb_alu2reg;

    wire                    if_stall;
    wire                    ex_stall;
    wire                    wb_stall;

    reg             [31: 0] fetch_pc;
    reg             [31: 0] wb_pc;
    reg             [31: 0] wb_result;
    reg             [ 2: 0] wb_alu_op;
    reg                     wb_memwr;
    reg                     wb_mem2reg;
    reg             [ 4: 0] wb_dst_sel;
    reg                     wb_branch;
    reg                     wb_branch_nxt;
    reg                     wb_nop;
    reg                     wb_nop_more;
    reg             [31: 0] wb_waddr;
    reg             [ 1: 0] wb_raddr;
    reg             [ 3: 0] wb_wstrb;
    reg             [31: 0] wb_wdata;
    reg             [31: 0] wb_rdata;
    wire                    wb_flush;

    reg                     illegal_inst;
    reg                     illegal_csr;

    reg             [63: 0] rdcycle;
    reg             [63: 0] rdinstret;

    integer                 i;

assign inst                 = flush ? NOP : imem_rdata;
assign if_stall             = !imem_valid;
assign dmem_waddr           = wb_waddr;
assign dmem_raddr           = alu_op1 + ex_imm;
assign dmem_rready          = ex_mem2reg;
assign dmem_wready          = wb_memwr;
assign dmem_wdata           = wb_wdata;
assign dmem_wstrb           = wb_wstrb;

always @(posedge clk or negedge resetb) begin
    if (!resetb)
        exception           <= 1'b0;
    else if (illegal_inst || illegal_csr || imem_addr[1:0] != 0)
        exception           <= 1'b1;
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        stall_r             <= 1'b1;
        flush               <= 1'b1;
    end else begin
        stall_r             <= stall;
        flush               <= stall_r;
    end
end

////////////////////////////////////////////////////////////
//      F/D  E   W
//          F/D  E   W
//              F/D  E  W
//                  F/D E  w 
////////////////////////////////////////////////////////////
// stage 1: fetch/decode
////////////////////////////////////////////////////////////
    reg             [31: 0] imm;

always @* begin
    imm                     = 32'h0;
    illegal_inst            = 1'b0;

    case(inst[`OPCODE])
        OP_AUIPC : imm      = {inst[31:12], 12'd0}; // U-type
        OP_LUI   : imm      = {inst[31:12], 12'd0}; // U-type
        OP_JAL   : imm      = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0}; // J-type
        OP_JALR  : imm      = {{20{inst[31]}}, inst[31:20]}; // I-Type 
        OP_BRANCH: imm      = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0}; // B-type
        OP_LOAD  : imm      = {{20{inst[31]}}, inst[31:20]}; // I-type
        OP_STORE : imm      = {{20{inst[31]}}, inst[31:25], inst[11:7]}; // S-type
        OP_ARITHI: imm      = (inst[`FUNC3] == OP_SLL || inst[`FUNC3] == OP_SR) ? {27'h0, inst[24:20]} : {{20{inst[31]}}, inst[31:20]}; // I-type
        OP_ARITHR: imm      = 'd0; // R-type
        OP_FENCE : imm      = 'd0;
        OP_SYSTEM: imm      = {20'h0, inst[31:20]};
        default: begin // illegal instruction
            illegal_inst    = 1'b1;
            //$display("Illegal instruction");
            //$finish(2);
        end
    endcase
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        ex_imm              <= 32'h0;
        ex_imm_sel          <= 1'b0;
        ex_src1_sel         <= 5'h0;
        ex_src2_sel         <= 5'h0;
        ex_dst_sel          <= 5'h0;
        ex_alu_op           <= 3'h0;
        ex_subtype          <= 1'b0;
        ex_memwr            <= 1'b0;
        ex_mem2reg          <= 1'b0;
        ex_alu              <= 1'b0;
        ex_csr              <= 1'b0;
        ex_jal              <= 1'b0;
        ex_jalr             <= 1'b0;
        ex_branch           <= 1'b0;
        ex_pc               <= RESETVEC;
    end else if (!stall_r && !if_stall) begin
        ex_imm              <= imm;
        ex_imm_sel          <= (inst[`OPCODE] == OP_JALR  ) ||
                               (inst[`OPCODE] == OP_LOAD  ) ||
                               (inst[`OPCODE] == OP_ARITHI);
        ex_src1_sel         <= inst[`RS1];
        ex_src2_sel         <= inst[`RS2];
        ex_dst_sel          <= inst[`RD];
        ex_alu_op           <= inst[`FUNC3];
        ex_subtype          <= inst[`SUBTYPE] && !(inst[`OPCODE] == OP_ARITHI && inst[`FUNC3] == OP_ADD);
        ex_memwr            <= inst[`OPCODE] == OP_STORE;
        ex_mem2reg          <= inst[`OPCODE] == OP_LOAD;
        ex_alu              <= (inst[`OPCODE] == OP_ARITHI) ||
                               (inst[`OPCODE] == OP_ARITHR);
        ex_csr              <= (inst[`OPCODE] == OP_SYSTEM) && !(inst[`IMM12] == 'h0 || inst[`IMM12] == 'h1);
        ex_lui              <= inst[`OPCODE] == OP_LUI;
        ex_auipc            <= inst[`OPCODE] == OP_AUIPC;
        ex_jal              <= inst[`OPCODE] == OP_JAL;
        ex_jalr             <= inst[`OPCODE] == OP_JALR;
        ex_branch           <= inst[`OPCODE] == OP_BRANCH;
        ex_pc               <= if_pc;
    end
end

////////////////////////////////////////////////////////////
// stage 2: execute
////////////////////////////////////////////////////////////
    wire            [31: 0] alu_op1;
    wire            [31: 0] alu_op2;
    wire            [32: 0] result_subs;
    wire            [32: 0] result_subu;
    reg             [31: 0] result;
    reg             [31: 0] next_pc;
    reg                     branch_taken;
    wire            [31: 0] wr_addr;
    wire                    ex_flush;

assign ex_stall             = if_stall || (ex_mem2reg && !dmem_rvalid);
assign alu_op1[31: 0]       = reg_rdata1;
assign alu_op2[31: 0]       = (ex_imm_sel) ? ex_imm : reg_rdata2;

assign result_subs[32: 0]   = {alu_op1[31], alu_op1} - {alu_op2[31], alu_op2};
assign result_subu[32: 0]   = {1'b0, alu_op1} - {1'b0, alu_op2};
assign wr_addr              = alu_op1 + ex_imm;
assign ex_flush             = wb_branch || wb_branch_nxt;

always @* begin
    branch_taken = !ex_flush;
    case(1'b1)
        ex_jal   : next_pc = ex_pc + ex_imm;
        ex_jalr  : next_pc = alu_op1 + ex_imm;
        ex_branch: begin
            case(ex_alu_op)
                OP_BEQ : begin
                            next_pc = (result_subs[32: 0] == 'd0) ? ex_pc + ex_imm : fetch_pc + 4;
                            if (result_subs[32: 0] != 'd0) branch_taken = 1'b0;
                         end
                OP_BNE : begin
                            next_pc = (result_subs[32: 0] != 'd0) ? ex_pc + ex_imm : fetch_pc + 4;
                            if (result_subs[32: 0] == 'd0) branch_taken = 1'b0;
                         end
                OP_BLT : begin
                            next_pc = result_subs[32] ? ex_pc + ex_imm : fetch_pc + 4;
                            if (!result_subs[32]) branch_taken = 1'b0;
                         end
                OP_BGE : begin
                            next_pc = !result_subs[32] ? ex_pc + ex_imm : fetch_pc + 4;
                            if (result_subs[32]) branch_taken = 1'b0;
                         end
                OP_BLTU: begin
                            next_pc = result_subu[32] ? ex_pc + ex_imm : fetch_pc + 4;
                            if (!result_subu[32]) branch_taken = 1'b0;
                         end
                OP_BGEU: begin
                            next_pc = !result_subu[32] ? ex_pc + ex_imm : fetch_pc + 4;
                            if (result_subu[32]) branch_taken = 1'b0;
                         end
                default: begin
                         $display("Unknown branch instruction");
                         $finish(2);
                         end
            endcase
        end
        default  : begin
                   next_pc              = fetch_pc + 4;
                   branch_taken         = 1'b0;
                   end
    endcase
end

always @* begin
    case(1'b1)
        ex_memwr:   result          = alu_op2;
        ex_jal:     result          = ex_pc + 4;
        ex_jalr:    result          = ex_pc + 4;
        ex_lui:     result          = ex_imm;
        ex_auipc:   result          = ex_pc + ex_imm;
        ex_csr:     result          = csr_read;
        ex_alu:
            case(ex_alu_op)
                OP_ADD : if (ex_subtype == 1'b0)
                            result  = alu_op1 + alu_op2;
                         else
                            result  = alu_op1 - alu_op2;
                OP_SLL : result     = alu_op1 << alu_op2;
                OP_SLT : result     = result_subs[32] ? 'd1 : 'd0;
                OP_SLTU: result     = result_subu[32] ? 'd1 : 'd0;
                OP_XOR : result     = alu_op1 ^ alu_op2;
                OP_SR  : if (ex_subtype == 1'b0)
                            result  = alu_op1 >> alu_op2;
                         else begin
                            result  = alu_op1 >> alu_op2;
                            /* verilator lint_off WIDTH */
                            for(i = 0; i < alu_op2[4:0]; i = i + 1) result[31-i] = alu_op1[31];
                            /* verilator lint_on WIDTH */
                         end
                OP_OR  : result     = alu_op1 | alu_op2;
                OP_AND : result     = alu_op1 & alu_op2;
                default: result     = 'hx;
            endcase
        default: result = 'hx;
    endcase
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        fetch_pc            <= RESETVEC;
    end else if (!stall_r && !ex_stall) begin
        fetch_pc            <= (ex_flush) ? fetch_pc + 4 : next_pc;
    end
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        wb_result           <= 32'h0;
        wb_memwr            <= 1'b0;
        wb_alu2reg          <= 1'b0;
        wb_dst_sel          <= 5'h0;
        wb_branch           <= 1'b0;
        wb_branch_nxt       <= 1'b0;
        wb_mem2reg          <= 1'b0;
        wb_raddr            <= 2'h0;
        wb_alu_op           <= 3'h0;
    end else if (!stall_r && !ex_stall) begin
        wb_result           <= result;
        wb_memwr            <= ex_memwr && !ex_flush;
        wb_alu2reg          <= ex_alu | ex_lui | ex_auipc | ex_jal | ex_jalr | ex_csr | ex_mem2reg;
        wb_dst_sel          <= ex_dst_sel;
        wb_branch           <= branch_taken;
        wb_branch_nxt       <= wb_branch;
        wb_mem2reg          <= ex_mem2reg;
        wb_raddr            <= dmem_raddr[1:0];
        wb_alu_op           <= ex_alu_op;
    end
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        wb_waddr            <= 32'h0;
        wb_wstrb            <= 4'h0;
        wb_wdata            <= 32'h0;
    end else if (!stall_r && !ex_stall && ex_memwr) begin
        wb_waddr            <= wr_addr;
        case(ex_alu_op)
            OP_SB: begin
                wb_wdata    <= {4{alu_op2[7:0]}};
                case(wr_addr[1:0])
                    2'b00:  wb_wstrb <= 4'b0001;
                    2'b01:  wb_wstrb <= 4'b0010;
                    2'b10:  wb_wstrb <= 4'b0100;
                    default:wb_wstrb <= 4'b1000;
                endcase
            end
            OP_SH: begin
                wb_wdata    <= {2{alu_op2[15:0]}};
                wb_wstrb    <= wr_addr[1] ? 4'b1100 : 4'b0011;
            end
            OP_SW: begin
                wb_wdata    <= alu_op2;
                wb_wstrb    <= 4'hf;
            end
            default: begin
                wb_wdata    <= {32{1'hx}};
                wb_wstrb    <= 4'hx;
            end
        endcase
    end
end

////////////////////////////////////////////////////////////
// stage 3: write back
////////////////////////////////////////////////////////////
assign imem_addr            = fetch_pc;
assign imem_ready           = !stall_r && !wb_stall;
assign wb_stall             = ex_stall || (wb_memwr && !dmem_wvalid);
assign wb_flush             = wb_nop || wb_nop_more;

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        if_pc               <= RESETVEC;
    end else if (!stall_r && !wb_stall) begin
        if_pc               <= fetch_pc;
    end
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        wb_nop              <= 1'b0;
        wb_nop_more         <= 1'b0;
    end else if (!stall_r && !(ex_stall || (wb_memwr && !dmem_wvalid))) begin
        wb_nop              <= wb_branch;
        wb_nop_more         <= wb_nop;
    end
end

always @* begin
    case(wb_alu_op)
        OP_LB  : begin
                    case(wb_raddr[1:0])
                        2'b00: wb_rdata[31: 0] = {{24{dmem_rdata[7]}}, dmem_rdata[7:0]};
                        2'b01: wb_rdata[31: 0] = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
                        2'b10: wb_rdata[31: 0] = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
                        2'b11: wb_rdata[31: 0] = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
                    endcase
                 end
        OP_LH  : wb_rdata = (wb_raddr[1]) ? {{16{dmem_rdata[31]}}, dmem_rdata[31:16]} : {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
        OP_LW  : wb_rdata = dmem_rdata;
        OP_LBU : begin
                    case(wb_raddr[1:0])
                        2'b00: wb_rdata[31: 0] = {24'h0, dmem_rdata[7:0]};
                        2'b01: wb_rdata[31: 0] = {24'h0, dmem_rdata[15:8]};
                        2'b10: wb_rdata[31: 0] = {24'h0, dmem_rdata[23:16]};
                        2'b11: wb_rdata[31: 0] = {24'h0, dmem_rdata[31:24]};
                    endcase
                 end
        OP_LHU : wb_rdata = (wb_raddr[1]) ? {16'h0, dmem_rdata[31:16]} : {16'h0, dmem_rdata[15:0]};
        default: wb_rdata = 'hx;
    endcase
end

////////////////////////////////////////////////////////////
// CSR file (only support read-only registers)
//  rdcycle
//  rdinstret
////////////////////////////////////////////////////////////
    wire            ex_csr_rd;
    reg     [31: 0] csr_read;

always @* begin
    if (ex_csr) begin
        case (ex_imm[11:0])
            CSR_RDCYCLE    : csr_read <= rdcycle[31:0];
            CSR_RDCYCLEH   : csr_read <= rdcycle[63:32];
            CSR_RDINSTRET  : csr_read <= rdinstret[31:0];
            CSR_RDINSTRETH : csr_read <= rdinstret[63:32];
            default: begin
                illegal_csr <= 1'b1;
                $display("Unsupport CSR register %0x", ex_imm[11:0]);
            end
        endcase
    end else begin
        illegal_csr <= 1'b0;
        csr_read    <= 32'h0;
    end
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        rdcycle             <= 64'h0;
        rdinstret           <= 64'h0;
    end else if (!stall_r) begin
        rdcycle             <= rdcycle + 1'b1;
        if (!ex_stall && !ex_flush) begin
            rdinstret       <= rdinstret + 1'b1;
        end
    end
end

////////////////////////////////////////////////////////////
// Register file
////////////////////////////////////////////////////////////
// Read address  : ex_src1_sel, ex_src2_sel.
// Read data out : reg_rdata1, reg_rdata2
// Write enable  : wb_alu2reg
// Write address : wb_dst_sel
// Write data    : wb_result
////////////////////////////////////////////////////////////
assign reg_rdata1[31: 0]    = (ex_src1_sel == 5'h0) ? 32'h0 :
                              (!wb_flush && wb_alu2reg && (wb_dst_sel == ex_src1_sel)) ? (wb_mem2reg ? wb_rdata : wb_result) :
                              regs[ex_src1_sel];
assign reg_rdata2[31: 0]    = (ex_src2_sel == 5'h0) ? 32'h0 :
                              (!wb_flush && wb_alu2reg && (wb_dst_sel == ex_src2_sel)) ? (wb_mem2reg ? wb_rdata : wb_result) :
                              regs[ex_src2_sel];

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        for(i = 1; i < 32; i = i + 1) regs[i] <= 32'h0;
    end else if (wb_alu2reg && !stall_r && !(wb_stall || wb_flush)) begin
        regs[wb_dst_sel]    <= wb_mem2reg ? wb_rdata : wb_result;
    end
end

// for debugging
`ifndef SYNTHESIS
    wire        [31: 0] x0_zero     = 'd0;
    wire        [31: 0] x1_ra       = regs[ 1][31: 0];
    wire        [31: 0] x2_sp       = regs[ 2][31: 0];
    wire        [31: 0] x3_gp       = regs[ 3][31: 0];
    wire        [31: 0] x4_tp       = regs[ 4][31: 0];
    wire        [31: 0] x5_t0       = regs[ 5][31: 0];
    wire        [31: 0] x6_t1       = regs[ 6][31: 0];
    wire        [31: 0] x7_t2       = regs[ 7][31: 0];
    wire        [31: 0] x8_s0_fp    = regs[ 8][31: 0];
    wire        [31: 0] x9_s1       = regs[ 9][31: 0];
    wire        [31: 0] x10_a0      = regs[10][31: 0];
    wire        [31: 0] x11_a1      = regs[11][31: 0];
    wire        [31: 0] x12_a2      = regs[12][31: 0];
    wire        [31: 0] x13_a3      = regs[13][31: 0];
    wire        [31: 0] x14_a4      = regs[14][31: 0];
    wire        [31: 0] x15_a5      = regs[15][31: 0];
    wire        [31: 0] x16_a6      = regs[16][31: 0];
    wire        [31: 0] x17_a7      = regs[17][31: 0];
    wire        [31: 0] x18_s2      = regs[18][31: 0];
    wire        [31: 0] x19_s3      = regs[19][31: 0];
    wire        [31: 0] x20_s4      = regs[20][31: 0];
    wire        [31: 0] x21_s5      = regs[21][31: 0];
    wire        [31: 0] x22_s6      = regs[22][31: 0];
    wire        [31: 0] x23_s7      = regs[23][31: 0];
    wire        [31: 0] x24_s8      = regs[24][31: 0];
    wire        [31: 0] x25_s9      = regs[25][31: 0];
    wire        [31: 0] x26_s10     = regs[26][31: 0];
    wire        [31: 0] x27_s11     = regs[27][31: 0];
    wire        [31: 0] x28_t3      = regs[28][31: 0];
    wire        [31: 0] x29_t4      = regs[29][31: 0];
    wire        [31: 0] x30_t5      = regs[30][31: 0];
    wire        [31: 0] x31_t6      = regs[31][31: 0];
    reg         [31: 0] ex_insn;
    reg         [31: 0] wb_insn;
    reg         [31: 0] wb_raddress;

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        ex_insn             <= 32'h0;
    end else if (!stall_r && !if_stall) begin
        ex_insn             <= inst;
    end
end

always @(posedge clk or negedge resetb) begin
    if (!resetb) begin
        wb_pc               <= RESETVEC;
        wb_insn             <= 32'h0;
    end else if (!stall_r && !ex_stall) begin
        wb_pc               <= ex_pc;
        wb_insn             <= ex_insn;
    end
end

always @(posedge clk) begin
    if (!stall_r && !ex_stall) begin
        wb_raddress         <= dmem_raddr[31:0];
    end
end
`endif // SYNTHESIS

endmodule
