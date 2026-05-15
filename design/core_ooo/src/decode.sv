// OoO core v1 — decode (RV32I)
//
// M0 scope: full RV32I — LUI, AUIPC, JAL, JALR, BRANCH×6, LOAD×5,
// STORE×3, OP_I (incl. shifts), OP_R, MISC_MEM (FENCE as nop). SYSTEM
// (ecall/ebreak/CSR) is flagged illegal for M0 and lands in M7.
//
// M2 phase B adds the M extension — funct7=0000001 in OP_R steers to
// FU_MULDIV with the matching mul_op.
//
// M6 adds the B extension (Zba/Zbb/Zbc/Zbs) + Zicond — fu stays at
// FU_ALU but bit_op is set. The execute stage drives the ALU's
// bit_op_i path so the same FU handles both base ALU and bit ops.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module decode
(
    input  logic [31:0]     instr_i,
    input  logic [31:0]     pc_i,
    input  onebit_sig_e     valid_i,
    // BPU prediction stamped on this fetch (M3-B).
    input  logic            pred_taken_i,
    input  logic [31:0]     pred_target_i,
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
        uop_o.pred_taken     = onebit_sig_e'(pred_taken_i);
        uop_o.pred_target    = pred_target_i;
        uop_o.csr_op         = OOO_CSR_NONE;
        uop_o.csr_addr       = 12'b0;
        uop_o.csr_uimm5      = 5'b0;
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

                OP_I: begin                       // ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI + Zb*-I
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
                        3'b001: begin                        // SLLI / Zb*-I (BSETI/BCLRI/BINVI/CLZ/CTZ/CPOP/SEXTB/SEXTH)
                            unique case (funct7)
                                7'b0000000: uop_o.alu_op = SLL;
                                7'b0010100: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BSETI; end
                                7'b0100100: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BCLRI; end
                                7'b0110100: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BINVI; end
                                7'b0110000: begin
                                    // CLZ/CTZ/CPOP/SEXTB/SEXTH encoded by rs2 (=funct5)
                                    uop_o.alu_op = NO_ALU_OP;
                                    unique case (rs2)
                                        5'b00000: uop_o.bit_op = CLZ;
                                        5'b00001: uop_o.bit_op = CTZ;
                                        5'b00010: uop_o.bit_op = CPOP;
                                        5'b00100: uop_o.bit_op = SEXTB;
                                        5'b00101: uop_o.bit_op = SEXTH;
                                        default:  uop_o.illegal = TRUE;
                                    endcase
                                    // rs2 here is the funct5 field, not an actual operand
                                end
                                default: uop_o.illegal = TRUE;
                            endcase
                        end
                        3'b101: begin                        // SRLI / SRAI / Zb*-I (BEXTI/RORI/ORCB/REV8)
                            unique case (funct7)
                                7'b0000000: uop_o.alu_op = SRL;
                                7'b0100000: uop_o.alu_op = SRA;
                                7'b0100100: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BEXTI; end
                                7'b0110000: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = RORI;  end
                                7'b0010100: if (rs2 == 5'b00111) begin
                                                uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ORCB;
                                            end else uop_o.illegal = TRUE;
                                7'b0110100: if (rs2 == 5'b11000) begin
                                                uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = REV8;
                                            end else uop_o.illegal = TRUE;
                                default: uop_o.illegal = TRUE;
                            endcase
                        end
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                OP_R: begin                       // ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND + M + Zb*-R + Zicond
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
                        // Zba — funct7=0010000
                        {7'b0010000, 3'b010}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = SH1ADD; end
                        {7'b0010000, 3'b100}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = SH2ADD; end
                        {7'b0010000, 3'b110}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = SH3ADD; end
                        // Zbb min/max + Zbc clmul — funct7=0000101
                        {7'b0000101, 3'b001}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = CLMUL;  end
                        {7'b0000101, 3'b010}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = CLMULR; end
                        {7'b0000101, 3'b011}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = CLMULH; end
                        {7'b0000101, 3'b100}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = MIN;    end
                        {7'b0000101, 3'b101}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = MINU;   end
                        {7'b0000101, 3'b110}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = MAX;    end
                        {7'b0000101, 3'b111}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = MAXU;   end
                        // Zbb XNOR/ORN/ANDN — funct7=0100000
                        {7'b0100000, 3'b100}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = XNOR; end
                        {7'b0100000, 3'b110}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ORN;  end
                        {7'b0100000, 3'b111}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ANDN; end
                        // Zbb ROL/ROR — funct7=0110000
                        {7'b0110000, 3'b001}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ROL; end
                        {7'b0110000, 3'b101}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ROR; end
                        // Zbb ZEXTH — funct7=0000100 funct3=100
                        {7'b0000100, 3'b100}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = ZEXTH; end
                        // Zbs BCLR/BEXT/BINV/BSET — reg form
                        {7'b0100100, 3'b001}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BCLR; end
                        {7'b0100100, 3'b101}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BEXT; end
                        {7'b0110100, 3'b001}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BINV; end
                        {7'b0010100, 3'b001}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = BSET; end
                        // Zicond — funct7=0000111
                        {7'b0000111, 3'b101}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = CZERO_EQZ; end
                        {7'b0000111, 3'b111}: begin uop_o.alu_op = NO_ALU_OP; uop_o.bit_op = CZERO_NEZ; end
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                MISC_MEM: begin                    // FENCE / FENCE.I — nop at M0
                    uop_o.fu     = FU_NONE;
                    uop_o.has_rd = FALSE;
                end

                CSR: begin                        // SYSTEM (ecall/ebreak/CSR/mret) — M7
                    // funct3 distinguishes:
                    //   000     → ECALL / EBREAK / MRET (encoded in [31:20])
                    //   001/010/011 → CSRRW / CSRRS / CSRRC
                    //   101/110/111 → CSRRWI / CSRRSI / CSRRCI
                    uop_o.fu       = FU_CSR;
                    uop_o.csr_addr = instr_i[31:20];
                    unique case (funct3)
                        3'b000: begin
                            // No rd, no rs1/rs2.
                            uop_o.has_rd  = FALSE;
                            uop_o.has_rs1 = FALSE;
                            uop_o.has_rs2 = FALSE;
                            unique case (instr_i[31:20])
                                12'h000: begin uop_o.csr_op = OOO_CSR_NONE; /* ECALL — silent for now */ end
                                12'h001: begin uop_o.csr_op = OOO_CSR_NONE; /* EBREAK — silent for now */ end
                                12'h302: begin uop_o.csr_op = OOO_CSR_MRET; end
                                default: uop_o.illegal = TRUE;
                            endcase
                        end
                        3'b001: begin
                            uop_o.csr_op  = OOO_CSR_RW;
                            uop_o.has_rs1 = TRUE;
                            uop_o.has_rd  = TRUE;
                        end
                        3'b010: begin
                            uop_o.csr_op  = OOO_CSR_RS;
                            uop_o.has_rs1 = TRUE;
                            uop_o.has_rd  = TRUE;
                        end
                        3'b011: begin
                            uop_o.csr_op  = OOO_CSR_RC;
                            uop_o.has_rs1 = TRUE;
                            uop_o.has_rd  = TRUE;
                        end
                        3'b101: begin
                            uop_o.csr_op    = OOO_CSR_RWI;
                            uop_o.csr_uimm5 = rs1;     // rs1 field = uimm5
                            uop_o.has_rs1   = FALSE;
                            uop_o.has_rd    = TRUE;
                        end
                        3'b110: begin
                            uop_o.csr_op    = OOO_CSR_RSI;
                            uop_o.csr_uimm5 = rs1;
                            uop_o.has_rs1   = FALSE;
                            uop_o.has_rd    = TRUE;
                        end
                        3'b111: begin
                            uop_o.csr_op    = OOO_CSR_RCI;
                            uop_o.csr_uimm5 = rs1;
                            uop_o.has_rs1   = FALSE;
                            uop_o.has_rd    = TRUE;
                        end
                        default: uop_o.illegal = TRUE;
                    endcase
                end

                default: begin
                    uop_o.illegal = TRUE;
                end

            endcase
        end
    end

endmodule
