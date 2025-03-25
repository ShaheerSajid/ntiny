import common_pkg::*;
import core_pkg::*;

module decoder
(
    input logic [31:0] instruction_i,
    output ctrl_bus_e ctrl_bus_o
);


rv32_opcodes_e inst_type;
br_cond_e br_cond;
load_store_width_e load_store_width;
onebit_sig_e mem_unsigned;
imm_sel_e imm_sel;
mem_op_e mem_op;
operand_e operand_a;
operand_e operand_b;
operand_e operand_c;
alu_op_e alu_op;
amo_op_e amo_op;
csr_op_e csr_op;
onebit_sig_e csr_use_immediate;
csr_reg_e csr_addr;
mul_op_e mul_op;
float_op_e float_op;
roundmode_e roundmode;
bit_op_e bit_op;
exec_result_e exec_result;
reg_add_e rs1_int;
reg_add_e rs2_int;
reg_add_e rs3_int;
reg_add_e rd_int;
reg_add_e rs1_float;
reg_add_e rs2_float;
reg_add_e rs3_float;
reg_add_e rd_float;
wb_sel_e wb_sel;

rv32_opcodes_e opcode;
logic [6:0] funct7;
logic [4:0] funct5;

assign opcode = rv32_opcodes_e'(instruction_i[6:0]);
assign funct5 = instruction_i[24:20];
assign funct7 = instruction_i[31:25];

always_comb
begin

    br_cond = NO_CONDITION;
    load_store_width = NO_WIDTH;
    mem_unsigned = FALSE;
    imm_sel = NO_IMM;
    mem_op = NO_MEM_OP;
    operand_a = NO_OPERAND;
    operand_b = NO_OPERAND;
    operand_c = NO_OPERAND;
    alu_op = NO_ALU_OP;
    amo_op = NO_AMO_OP;
    csr_op = NO_CSR_OP;
    csr_use_immediate = FALSE;
    csr_addr = NO_CSR_REG;
    mul_op = NO_MUL_OP;
    float_op = NO_FP_OP;
    roundmode = RNE;
    bit_op = NO_BIT_OP;
    exec_result = NO_EX_RES;
    rs1_int = NO_REG;
    rs2_int = NO_REG;
    rs3_int = NO_REG;
    rd_int = NO_REG;
    rs1_float = NO_REG;
    rs2_float = NO_REG;
    rs3_float = NO_REG;
    rd_float = NO_REG;
    wb_sel = NO_WB;

    case(opcode)
        LUI     :   begin  
                        imm_sel = U_imm; 
                        operand_b = IMM; 
                        alu_op = PASS;
                        exec_result = ALU_RES;
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = EXEC;
                    end
        AUIPC   :   begin 
                        imm_sel = U_imm; 
                        operand_a = PC;
                        operand_b = IMM;  
                        alu_op = ADD;
                        exec_result = ALU_RES;
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = EXEC;
                    end
        JUMP    :   begin
                        imm_sel = J_imm;
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = PC_WB;
                    end
        JUMP_R  :   begin
                        imm_sel = I_imm;
                        rs1_int = reg_add_e'(instruction_i[19:15]);   
                        rd_int = reg_add_e'(instruction_i[11:7]); 
                        wb_sel = PC_WB;
                    end
        BRANCH  :   begin
                        br_cond = br_cond_e'(instruction_i[14:12]);
                        imm_sel = B_imm;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rs2_int = reg_add_e'(instruction_i[24:20]);
                    end
        LOAD    :   begin
                        load_store_width = load_store_width_e'(instruction_i[13:12]);
                        mem_unsigned = onebit_sig_e'(instruction_i[14]);
                        imm_sel = I_imm;
                        mem_op = READ;
                        operand_a = REGISTER;
                        operand_b = IMM;
                        alu_op = ADD;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = MEMORY;
                    end
        STORE   :   begin
                        load_store_width = load_store_width_e'(instruction_i[13:12]);
                        imm_sel = S_imm;
                        mem_op = WRITE;
                        operand_a = REGISTER;
                        operand_b = IMM;
                        alu_op = ADD;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rs2_int = reg_add_e'(instruction_i[24:20]);
                    end
        OP_I    :   begin
                        imm_sel = I_imm;
                        operand_a = REGISTER;
                        operand_b = IMM;                           
                        case(instruction_i[14:12])
                            3'b000: alu_op = ADD;//addi
                            3'b001: case(funct7)
                                        7'b0000000: alu_op = SLL;//slli
                                        7'b0110000: case(funct5)
                                                        5'b00000: bit_op = CLZ;//clz
                                                        5'b00001: bit_op = CTZ;//ctz
                                                        5'b00010: bit_op = CPOP;//cpop
                                                        5'b00100: bit_op = SEXTB;//sext.b
                                                        5'b00101: bit_op = SEXTH;//sext.h
                                                    endcase
                                    endcase 
                            3'b010: alu_op = SLT;//slti
                            3'b011: alu_op = SLTU;//sltiu
                            3'b100: alu_op = XOR;//xori
                            3'b101: casez({funct7,funct5})
                                        {7'b0000000,5'b?????}: alu_op = SRL;//srli
                                        {7'b0100000,5'b?????}: alu_op = SRA;//srai
                                        {7'b0110000,5'b?????}: bit_op = RORI;//rori
                                        {7'b0010100,5'b00111}: bit_op = ORCB;//orc.b
                                        {7'b0110100,5'b11000}: bit_op = REV8;//rev8
                                    endcase
                            3'b110: alu_op = OR;//ori
                            3'b111: alu_op = AND;//andi
                        endcase
                        exec_result = ALU_RES;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = EXEC;
                    end
        OP_R    :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        case(funct7)
                            7'b0000000: case(instruction_i[14:12])
                                            3'b000: alu_op = ADD;//add
                                            3'b001: alu_op = SLL;//sll
                                            3'b010: alu_op = SLT;//slt
                                            3'b011: alu_op = SLTU;//sltu
                                            3'b100: alu_op = XOR;//xor
                                            3'b101: alu_op = SRL;//srl
                                            3'b110: alu_op = OR;//or
                                            3'b111: alu_op = AND;//and
                                        endcase       
                            7'b0000001: mul_op = mul_op_e'({1'b0,instruction_i[14:12]});
                            7'b0100000: case(instruction_i[14:12])
                                            3'b000: alu_op = SUB;//sub
                                            3'b100: bit_op = XNOR;
                                            3'b101: alu_op = SRA;//sra
                                            3'b110: bit_op = ORN;
                                            3'b111: bit_op = ANDN;
                                        endcase
                            7'b0010000: case(instruction_i[14:12])
                                            3'b010: bit_op = SH1ADD;
                                            3'b100: bit_op = SH2ADD;
                                            3'b110: bit_op = SH3ADD;
                                        endcase
                            7'b0000101: case(instruction_i[14:12])
                                            3'b100: bit_op = MIN;
                                            3'b101: bit_op = MINU;
                                            3'b110: bit_op = MAX;
                                            3'b111: bit_op = MAXU;
                                        endcase
                            7'b0110000: case(instruction_i[14:12])
                                            3'b001: bit_op = ROL;
                                            3'b101: bit_op = ROR;
                                        endcase  
                            7'b0000100: case(instruction_i[14:12])
                                            3'b100: bit_op = ZEXTH;
                                        endcase
                        endcase
                        exec_result = ALU_RES;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rs2_int = reg_add_e'(instruction_i[24:20]);
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = EXEC;
                    end
        AMO     :   begin // AMO Operations (7'b0101111)
                        load_store_width = load_store_width_e'(instruction_i[13:12]);
                        mem_unsigned = onebit_sig_e'(instruction_i[14]);
                        mem_op = READ_WRITE;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rs2_int = reg_add_e'(instruction_i[24:20]);
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        // Decode funct5 (bits 31:27) for specific AMO operations
                        case (instruction_i[31:27])
                            5'b00000: amo_op = AMO_ADD;
                            5'b00001: amo_op = AMO_SWAP;
                            5'b00010: amo_op = AMO_LR;
                            5'b00011: amo_op = AMO_SC;
                            5'b00100: amo_op = AMO_XOR;
                            5'b00101: amo_op = AMO_OR;
                            5'b00110: amo_op = AMO_AND;
                            5'b01000: amo_op = AMO_MIN;
                            5'b01001: amo_op = AMO_MAX;
                            5'b01100: amo_op = AMO_MINU;
                            5'b01101: amo_op = AMO_MAXU;
                            default: begin
                                amo_op = AMO_ADD; // Safe default
                            end
                        endcase
                    end
        CSR     :   begin
                        imm_sel = CSR_imm;
                        csr_op = csr_op_e'({1'b0,instruction_i[13:12]});
                        csr_use_immediate = onebit_sig_e'(instruction_i[14]);
                        csr_addr = csr_reg_e'(instruction_i[31:20]);
                        exec_result = CSR_RES;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rd_int = reg_add_e'(instruction_i[11:7]);
                        wb_sel = EXEC;
                    end
    `ifdef FPU
        FLOAD   :   begin
                        load_store_width = load_store_width_e'(instruction_i[13:12]);
                        mem_unsigned = onebit_sig_e'(instruction_i[14]);
                        imm_sel = I_imm;
                        mem_op = READ;
                        operand_a = REGISTER;
                        operand_b = IMM;
                        alu_op = ADD;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rd_float = reg_add_e'(instruction_i[11:7]);
                        wb_sel = MEMORY;
                    end
        FSTORE  :   begin
                        load_store_width = load_store_width_e'(instruction_i[13:12]);
                        imm_sel = S_imm;
                        mem_op = WRITE;
                        operand_a = REGISTER;
                        operand_b = IMM;
                        alu_op = ADD;
                        rs1_int = reg_add_e'(instruction_i[19:15]);
                        rs2_float = reg_add_e'(instruction_i[24:20]);
                    end
        FMADD   :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        operand_c = REGISTER;
                        roundmode = roundmode_e'(instruction_i[14:12]);  
                        float_op = FMADDS;        
                        rs1_float = reg_add_e'(instruction_i[19:15]);
                        rs2_float = reg_add_e'(instruction_i[24:20]);
                        rs3_float = reg_add_e'(instruction_i[31:27]);
                        rd_float = reg_add_e'(instruction_i[11:7]);
                        exec_result = ALU_RES;
                        wb_sel = EXEC;
                    end
        FMSUB   :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        operand_c = REGISTER;
                        roundmode = roundmode_e'(instruction_i[14:12]);  
                        float_op = FMSUBS;
                        rs1_float = reg_add_e'(instruction_i[19:15]);
                        rs2_float = reg_add_e'(instruction_i[24:20]);
                        rs3_float = reg_add_e'(instruction_i[31:27]);
                        rd_float = reg_add_e'(instruction_i[11:7]);       
                        exec_result = ALU_RES;
                        wb_sel = EXEC;
                    end
        FNMSUB  :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        operand_c = REGISTER;
                        roundmode = roundmode_e'(instruction_i[14:12]);  
                        float_op = FNMSUBS;
                        rs1_float = reg_add_e'(instruction_i[19:15]);
                        rs2_float = reg_add_e'(instruction_i[24:20]);
                        rs3_float = reg_add_e'(instruction_i[31:27]);
                        rd_float = reg_add_e'(instruction_i[11:7]);    
                        exec_result = ALU_RES;
                        wb_sel = EXEC;
                    end
        FNMADD  :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        operand_c = REGISTER;
                        roundmode = roundmode_e'(instruction_i[14:12]);  
                        float_op = FNMADDS;
                        rs1_float = reg_add_e'(instruction_i[19:15]);
                        rs2_float = reg_add_e'(instruction_i[24:20]);
                        rs3_float = reg_add_e'(instruction_i[31:27]);
                        rd_float = reg_add_e'(instruction_i[11:7]);         
                        exec_result = ALU_RES;
                        wb_sel = EXEC;
                    end
        F_OP    :   begin
                        operand_a = REGISTER;
                        operand_b = REGISTER;
                        roundmode = roundmode_e'(instruction_i[14:12]);             
                        case(funct7)
                            7'b0000000: float_op = FADDS;
                            7'b0000100: float_op = FSUBS;
                            7'b0001000: float_op = FMULS;
                            7'b0001100: float_op = FDIVS;
                            7'b0101100: float_op = FSQRTS;
                            7'b0010000: case(instruction_i[14:12])
                                            3'b000: float_op = FSGNJS;
                                            3'b001: float_op = FSGNJNS;
                                            3'b010: float_op = FSGNJXS;
                                        endcase
                            7'b0010100: case(instruction_i[14:12])
                                            3'b000: float_op = FMINS;
                                            3'b001: float_op = FMAXS;
                                        endcase
                            7'b1100000: case(funct5)
                                            5'b00000: float_op = FCVTWS;
                                            5'b00001: float_op = FCVTWUS;
                                        endcase
                            7'b1010000: case(instruction_i[14:12])
                                            3'b010: float_op = FEQS;
                                            3'b001: float_op = FLTS;
                                            3'b000: float_op = FLES;
                                        endcase
                            7'b1110000: case(instruction_i[14:12])
                                            3'b000: float_op = FMVXW;
                                            3'b001: float_op = FCLASSS;
                                        endcase
                            7'b1101000: case(funct5)
                                            5'b00000: float_op = FCVTSW;
                                            5'b00001: float_op = FCVTSWU;
                                        endcase
                            7'b1111000: float_op = FMVWX;
                        endcase

                        case(float_op)
                            FEQS, FLTS, 
                            FLES:           begin
                                                rs1_float = reg_add_e'(instruction_i[19:15]);
                                                rs2_float = reg_add_e'(instruction_i[24:20]);
                                                rd_int = reg_add_e'(instruction_i[11:7]);
                                            end
                            FCLASSS, FMVXW,
                            FCVTWS, FCVTWUS:begin
                                                rs1_float = reg_add_e'(instruction_i[19:15]);
                                                rd_int = reg_add_e'(instruction_i[11:7]);
                                            end
                            FMVWX, FCVTSW, 
                            FCVTSWU:        begin
                                                rs1_int = reg_add_e'(instruction_i[19:15]);
                                                rd_float = reg_add_e'(instruction_i[11:7]);
                                            end
                            FSQRTS:         begin
                                                rs1_float = reg_add_e'(instruction_i[19:15]);
                                                rd_float = reg_add_e'(instruction_i[11:7]);
                                            end
                            default:        begin
                                                rs1_float = reg_add_e'(instruction_i[19:15]);
                                                rs2_float = reg_add_e'(instruction_i[24:20]);
                                                rd_float = reg_add_e'(instruction_i[11:7]);
                                            end
                        endcase
                        exec_result = ALU_RES;
                        wb_sel = EXEC;
                    end
    `endif
    endcase
end

assign ctrl_bus_o.inst_type = opcode;
assign ctrl_bus_o.br_cond = br_cond;
assign ctrl_bus_o.load_store_width = load_store_width;
assign ctrl_bus_o.mem_unsigned = mem_unsigned;
assign ctrl_bus_o.imm_sel = imm_sel;
assign ctrl_bus_o.mem_op = mem_op;
assign ctrl_bus_o.operand_a = operand_a;
assign ctrl_bus_o.operand_b = operand_b;
assign ctrl_bus_o.operand_c = operand_c;
assign ctrl_bus_o.alu_op = alu_op;
assign ctrl_bus_o.csr_op = csr_op;
assign ctrl_bus_o.csr_use_immediate = csr_use_immediate;
assign ctrl_bus_o.csr_addr = csr_addr;
assign ctrl_bus_o.mul_op = mul_op;
assign ctrl_bus_o.float_op = float_op;
assign ctrl_bus_o.roundmode = roundmode;
assign ctrl_bus_o.bit_op = bit_op;
assign ctrl_bus_o.exec_result = exec_result;
assign ctrl_bus_o.rs1_int = rs1_int;
assign ctrl_bus_o.rs2_int = rs2_int;
assign ctrl_bus_o.rs3_int = rs3_int;
assign ctrl_bus_o.rd_int = rd_int;
assign ctrl_bus_o.rs1_float = rs1_float;
assign ctrl_bus_o.rs2_float = rs2_float;
assign ctrl_bus_o.rs3_float = rs3_float;
assign ctrl_bus_o.rd_float = rd_float;
assign ctrl_bus_o.wb_sel = wb_sel;
assign ctrl_bus_o.ebreak = onebit_sig_e'(csr_op == SYSTEM && csr_addr == 12'd1);
assign ctrl_bus_o.ecall = onebit_sig_e'(csr_op == SYSTEM && csr_addr == 12'd0);
assign ctrl_bus_o.mret = onebit_sig_e'(csr_op == SYSTEM && csr_addr == 12'h302);

endmodule

