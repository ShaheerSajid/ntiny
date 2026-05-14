// OoO core v1 — decode (RV32I)
//
// M0 scope: full RV32I — LUI, AUIPC, JAL, JALR, BRANCH×6, LOAD×5,
// STORE×3, OP_I (incl. shifts), OP_R, MISC_MEM (FENCE as nop). SYSTEM
// (ecall/ebreak/CSR) is flagged illegal for M0 and lands in M7.
//
// M2 phase B adds the M extension — funct7=0000001 in OP_R steers to
// FU_MULDIV with the matching mul_op. F lands in M5, B in M6.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module decode
(
    input  logic [31:0]     instr_i,
    input  logic [31:0]     pc_i,
    input  onebit_sig_e     valid_i,
    output uop_t            uop_o
);

    // ── instruction field slices ──────────────────────────────
    wire [6:0] opcode = instr_i[6:0];
    wire [2:0] funct3 = instr_i[14:12];
    wire [6:0] funct7 = instr_i[31:25];
    wire [4:0] rd     = instr_i[11:7];
    wire [4:0] rs1    = instr_i[19:15];
    wire [4:0] rs2    = instr_i[24:20];

    // ── immediate forms ───────────────────────────────────────
    wire [31:0] i_imm = {{20{instr_i[31]}}, instr_i[31:20]};
    wire [31:0] s_imm = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    wire [31:0] b_imm = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                          instr_i[30:25], instr_i[11:8], 1'b0};
    wire [31:0] u_imm = {instr_i[31:12], 12'b0};
    wire [31:0] j_imm = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                          instr_i[20], instr_i[30:21], 1'b0};

    always_comb begin
        uop_o                = '0;
        uop_o.pc             = pc_i;
        uop_o.instr          = instr_i;
        uop_o.valid          = valid_i;
        uop_o.fu             = FU_NONE;
        uop_o.alu_op         = NO_ALU_OP;
        uop_o.bit_op         = NO_BIT_OP;
        uop_o.mul_op         = NO_MUL_OP;
        uop_o.br_cond        = NO_CONDITION;
        uop_o.ls_width       = NO_WIDTH;
        uop_o.mem_unsigned   = FALSE;
        uop_o.rs1            = rs1;
        uop_o.rs2            = rs2;
        uop_o.rd             = rd;
        uop_o.has_rs1        = FALSE;
        uop_o.has_rs2        = FALSE;
        uop_o.has_rd         = FALSE;
        uop_o.alu_imm        = 32'b0;
        uop_o.uses_imm       = FALSE;
        uop_o.uses_pc        = FALSE;
        uop_o.br_imm         = 32'b0;
        uop_o.is_branch      = FALSE;
        uop_o.is_jump        = FALSE;
        uop_o.is_jalr        = FALSE;
        uop_o.illegal        = FALSE;

        if (valid_i == TRUE) begin
            unique case (rv32_opcodes_e'(opcode))

                LUI: begin
                    uop_o.fu       = FU_ALU;
                    uop_o.alu_op   = PASS;        // result = b_i
                    uop_o.alu_imm  = u_imm;
                    uop_o.uses_imm = TRUE;
                    uop_o.uses_pc  = FALSE;       // A unused; will tie to 0
                    uop_o.has_rd   = TRUE;
                end

                AUIPC: begin
                    uop_o.fu       = FU_ALU;
                    uop_o.alu_op   = ADD;
                    uop_o.alu_imm  = u_imm;
                    uop_o.uses_imm = TRUE;
                    uop_o.uses_pc  = TRUE;
                    uop_o.has_rd   = TRUE;
                end

                JUMP: begin                       // JAL
                    uop_o.fu       = FU_BRANCH;
                    uop_o.alu_op   = ADD;         // rd = pc + 4
                    uop_o.alu_imm  = 32'd4;
                    uop_o.uses_imm = TRUE;
                    uop_o.uses_pc  = TRUE;
                    uop_o.has_rd   = TRUE;
                    uop_o.is_jump  = TRUE;
                    uop_o.br_imm   = j_imm;
                end

                JUMP_R: begin                     // JALR
                    uop_o.fu       = FU_BRANCH;
                    uop_o.alu_op   = ADD;         // rd = pc + 4
                    uop_o.alu_imm  = 32'd4;
                    uop_o.uses_imm = TRUE;
                    uop_o.uses_pc  = TRUE;
                    uop_o.has_rd   = TRUE;
                    uop_o.has_rs1  = TRUE;
                    uop_o.is_jalr  = TRUE;
                    uop_o.br_imm   = i_imm;
                    if (funct3 != 3'b000) uop_o.illegal = TRUE;
                end

                BRANCH: begin
                    uop_o.fu        = FU_BRANCH;
                    uop_o.alu_op    = NO_ALU_OP;  // compare path, no ALU rd
                    uop_o.has_rs1   = TRUE;
                    uop_o.has_rs2   = TRUE;
                    uop_o.has_rd    = FALSE;
                    uop_o.is_branch = TRUE;
                    uop_o.br_imm    = b_imm;
                    unique case (funct3)
                        3'b000: uop_o.br_cond = BEQ;
                        3'b001: uop_o.br_cond = BNE;
                        3'b100: uop_o.br_cond = BLT;
                        3'b101: uop_o.br_cond = BGE;
                        3'b110: uop_o.br_cond = BLTU;
                        3'b111: uop_o.br_cond = BGEU;
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                LOAD: begin
                    uop_o.fu           = FU_LOAD;
                    uop_o.alu_op       = ADD;     // address = rs1 + I-imm
                    uop_o.alu_imm      = i_imm;
                    uop_o.uses_imm     = TRUE;
                    uop_o.has_rs1      = TRUE;
                    uop_o.has_rd       = TRUE;
                    unique case (funct3)
                        3'b000: begin uop_o.ls_width = BYTE; uop_o.mem_unsigned = FALSE; end // LB
                        3'b001: begin uop_o.ls_width = HALF; uop_o.mem_unsigned = FALSE; end // LH
                        3'b010: begin uop_o.ls_width = WORD; uop_o.mem_unsigned = FALSE; end // LW
                        3'b100: begin uop_o.ls_width = BYTE; uop_o.mem_unsigned = TRUE;  end // LBU
                        3'b101: begin uop_o.ls_width = HALF; uop_o.mem_unsigned = TRUE;  end // LHU
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                STORE: begin
                    uop_o.fu           = FU_STORE;
                    uop_o.alu_op       = ADD;     // address = rs1 + S-imm
                    uop_o.alu_imm      = s_imm;
                    uop_o.uses_imm     = TRUE;
                    uop_o.has_rs1      = TRUE;
                    uop_o.has_rs2      = TRUE;
                    uop_o.has_rd       = FALSE;
                    unique case (funct3)
                        3'b000: uop_o.ls_width = BYTE;   // SB
                        3'b001: uop_o.ls_width = HALF;   // SH
                        3'b010: uop_o.ls_width = WORD;   // SW
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                OP_I: begin                       // ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI
                    uop_o.fu        = FU_ALU;
                    uop_o.alu_imm   = i_imm;
                    uop_o.uses_imm  = TRUE;
                    uop_o.has_rs1   = TRUE;
                    uop_o.has_rd    = TRUE;
                    unique case (funct3)
                        3'b000: uop_o.alu_op = ADD;          // ADDI
                        3'b010: uop_o.alu_op = SLT;          // SLTI
                        3'b011: uop_o.alu_op = SLTU;         // SLTIU
                        3'b100: uop_o.alu_op = XOR;          // XORI
                        3'b110: uop_o.alu_op = OR;           // ORI
                        3'b111: uop_o.alu_op = AND;          // ANDI
                        3'b001: begin                        // SLLI
                            uop_o.alu_op = SLL;
                            if (funct7 != 7'b0000000) uop_o.illegal = TRUE;
                        end
                        3'b101: begin                        // SRLI / SRAI
                            if (funct7 == 7'b0000000)       uop_o.alu_op = SRL;
                            else if (funct7 == 7'b0100000)  uop_o.alu_op = SRA;
                            else                            uop_o.illegal = TRUE;
                        end
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                OP_R: begin                       // ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND
                    uop_o.fu       = FU_ALU;
                    uop_o.uses_imm = FALSE;
                    uop_o.has_rs1  = TRUE;
                    uop_o.has_rs2  = TRUE;
                    uop_o.has_rd   = TRUE;
                    unique case ({funct7, funct3})
                        {7'b0000000, 3'b000}: uop_o.alu_op = ADD;
                        {7'b0100000, 3'b000}: uop_o.alu_op = SUB;
                        {7'b0000000, 3'b001}: uop_o.alu_op = SLL;
                        {7'b0000000, 3'b010}: uop_o.alu_op = SLT;
                        {7'b0000000, 3'b011}: uop_o.alu_op = SLTU;
                        {7'b0000000, 3'b100}: uop_o.alu_op = XOR;
                        {7'b0000000, 3'b101}: uop_o.alu_op = SRL;
                        {7'b0100000, 3'b101}: uop_o.alu_op = SRA;
                        {7'b0000000, 3'b110}: uop_o.alu_op = OR;
                        {7'b0000000, 3'b111}: uop_o.alu_op = AND;
                        // M extension — funct7=0000001
                        {7'b0000001, 3'b000}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = MUL;    end
                        {7'b0000001, 3'b001}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = MULH;   end
                        {7'b0000001, 3'b010}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = MULHSU; end
                        {7'b0000001, 3'b011}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = MULHU;  end
                        {7'b0000001, 3'b100}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = DIV;    end
                        {7'b0000001, 3'b101}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = DIVU;   end
                        {7'b0000001, 3'b110}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = REM;    end
                        {7'b0000001, 3'b111}: begin uop_o.fu = FU_MULDIV; uop_o.alu_op = NO_ALU_OP; uop_o.mul_op = REMU;   end
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                MISC_MEM: begin                    // FENCE / FENCE.I — nop at M0
                    uop_o.fu     = FU_NONE;
                    uop_o.has_rd = FALSE;
                end

                CSR: begin                        // SYSTEM (ecall/ebreak/CSR) — M7
                    uop_o.fu      = FU_NONE;
                    uop_o.illegal = TRUE;
                end

                default: begin
                    uop_o.illegal = TRUE;
                end

            endcase
        end
    end

endmodule
