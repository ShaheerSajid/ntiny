package core_pkg;
import common_pkg::*;
`define OPCODE_LENGTH	7

//Define Opcodes
typedef enum logic [`OPCODE_LENGTH-1:0] {
	LUI		= 7'b0110111,
	AUIPC	= 7'b0010111,
	JUMP	= 7'b1101111,
	JUMP_R	= 7'b1100111,
	BRANCH	= 7'b1100011,
	LOAD	= 7'b0000011,
	STORE	= 7'b0100011,
	OP_I	= 7'b0010011,
	OP_R	= 7'b0110011,
	CSR		= 7'b1110011,
	FLOAD	= 7'b0000111,
	FSTORE	= 7'b0100111,
	FMADD	= 7'b1000011,
	FMSUB	= 7'b1000111,
	FNMSUB	= 7'b1001011,
	FNMADD	= 7'b1001111,
	F_OP	= 7'b1010011,
	AMO		= 7'b0101111,
	NO_INS	= 7'b0000000
} rv32_opcodes_e;


//conditional branch types
typedef enum logic[2:0] {
	BEQ,
	BNE,
	NO_CONDITION,
	BLT = 3'b100,
	BGE,
	BLTU,
	BGEU
} br_cond_e;

//load-store widths
typedef enum logic[1:0] {
	BYTE,
	HALF,
	WORD,
	NO_WIDTH
} load_store_width_e;

//integer
typedef enum logic[3:0] {
	ADD,
	SUB,
	SLL,
	SLT,
	SLTU,
	XOR,
	SRL,
	SRA,
	OR,
	AND,
	PASS,
	NO_ALU_OP
} alu_op_e;

//bit
typedef enum logic[4:0] {
	SH1ADD,
	SH2ADD,
	SH3ADD,
	ANDN,
	ORN,
	XNOR,
	CLZ,
	CTZ,
	CPOP,
	MAX,
	MAXU,
	MIN,
	MINU,
	SEXTB,
	SEXTH,
	ZEXTH,
	ROL,
	ROR,
	RORI,
	ORCB,
	REV8,
	NO_BIT_OP
} bit_op_e;

//mul/div
typedef enum logic[3:0] {
	MUL,
	MULH,
	MULHSU,
	MULHU,
	DIV,
	DIVU,
	REM,
	REMU,
	NO_MUL_OP
} mul_op_e;

//atomic (A-extension)
typedef enum logic[3:0] {
	AMOADD,
	AMOSWAP,
	LR_W,
	SC_W,
	AMOXOR,
	AMOMIN,
	AMOMAX,
	AMOMINU,
	AMOMAXU,
	AMOOR,
	AMOAND,
	NO_AMO_OP
} amo_op_e;

//floating
typedef enum logic[4:0] {
	FMADDS,
	FMSUBS,
	FNMSUBS,
	FNMADDS,
	FADDS,
	FSUBS,
	FMULS,
	FDIVS,
	FSQRTS,
	FSGNJS,
	FSGNJNS,
	FSGNJXS,
	FMINS,
	FMAXS,
	FCVTWS,
	FCVTWUS,
	FMVXW,
	FEQS,
	FLTS,
	FLES,
	FCLASSS,
	FCVTSW,
	FCVTSWU,
	FMVWX,
	NO_FP_OP
} float_op_e;

typedef enum logic [2:0] {
    RNE = 3'b000,
    RTZ = 3'b001,
    RDN = 3'b010,
    RUP = 3'b011,
    RMM = 3'b100,
    DYN = 3'b111
} roundmode_e;

typedef struct packed {
    onebit_sig_e NV; // Invalid
    onebit_sig_e DZ; // Divide by zero
    onebit_sig_e OF; // Overflow
    onebit_sig_e UF; // Underflow
    onebit_sig_e NX; // Inexact
} float_status_e;

//csr op
typedef enum logic[2:0] {
	SYSTEM,
	WRITE_CSR,
	SET_CSR,
	CLEAR_CSR,
	NO_CSR_OP
} csr_op_e;

//csr registers
typedef enum logic[11:0] {
	NO_CSR_REG,
	//User Mode
	FFLAGS			= 12'h001,
	FRM 			= 12'h002,
	FCSR 			= 12'h003,
	CYCLE 			= 12'hc00,
	TIME 			= 12'hc01,
	INSTRET 		= 12'hc02,
	CYCLEH 			= 12'hc80,
	TIMEH 			= 12'hc81,
	INSTRETH 		= 12'hc82,
	//Machine mode
	MVENDORID 		= 12'hf11,
	MARCHID 		= 12'hf12,
	MIMPID 			= 12'hf13,
	MHARTID 		= 12'hf14,
	MEDELEG  		= 12'h302,
    MIDELEG 	 	= 12'h303,
	MSTATUS 		= 12'h300,
	MISA 			= 12'h301,
	MIE 			= 12'h304,
	MTVEC 			= 12'h305,
	MCOUNTEREN 		= 12'h306,
	MSTATUSH 		= 12'h310,
	MSCRATCH 		= 12'h340,
	MEPC 			= 12'h341,
	MCAUSE 			= 12'h342,
	MTVAL 			= 12'h343,
	MIP 			= 12'h344,
	MCYCLE			= 12'hb00,
	MINSTRET 		= 12'hb02,
	MCYCLEH 		= 12'hb80,
	MINSTRETH 		= 12'hb82,
	MCOUNTINHIBIT 	= 12'h320,
	DCSR			= 12'h7b0,
	DPC 			= 12'h7b1,
	//Supervisor Mode
	SSTATUS     	= 12'h100,
   	SIE         	= 12'h104,
    STVEC       	= 12'h105,
    SCOUNTEREN  	= 12'h106,
    SSCRATCH    	= 12'h140,
    SEPC        	= 12'h141,
    SCAUSE      	= 12'h142,
    SBADADDR    	= 12'h143,
    SIP         	= 12'h144,
    SATP        	= 12'h180
} csr_reg_e;

//internal
typedef enum logic[5:0] {
	R[32],
	NO_REG
} reg_add_e;

typedef enum logic[2:0] {
	I_imm,
	S_imm,
	B_imm,
	U_imm,
	J_imm,
	CSR_imm,
	NO_IMM
} imm_sel_e;

typedef enum logic[1:0] {
	READ,
	WRITE,
	NO_MEM_OP
} mem_op_e;

typedef enum logic[1:0] {
	ALU_RES,
	CSR_RES,
	NO_EX_RES
} exec_result_e;

typedef enum logic[1:0] {
	IMM,
	PC,
	REGISTER,
	NO_OPERAND
} operand_e;

typedef enum logic[1:0] {
	NO_FORWARD,
	FORWARD_IMEM,
	FORWARD_IWB
} forward_sel_e;

typedef enum logic[2:0] {
	EXEC,
	MEMORY,
	PC_WB,
	NO_WB
} wb_sel_e;

typedef enum logic[2:0] {
	PC_plus_4,
	BRANCH_PC,
	INTERRUPT,
	RET,
	BRANCH_DPC
} pc_sel_e;

// Control bus — decoded instruction fields, propagated through pipeline stages.
// Groups: instruction type, branch, memory, ALU/MUL/FPU/BIT ops, CSR, register addresses, writeback.
typedef struct {
	rv32_opcodes_e inst_type;       // opcode category
	br_cond_e br_cond;              // branch condition (BEQ, BNE, etc.)
	load_store_width_e load_store_width; // BYTE/HALF/WORD
	onebit_sig_e mem_unsigned;      // unsigned load (LBU, LHU)
	imm_sel_e imm_sel;              // immediate format (I/S/B/U/J/CSR)
	mem_op_e mem_op;                // READ/WRITE/NO_MEM_OP
	operand_e operand_a;            // ALU source A select
	operand_e operand_b;            // ALU source B select
	operand_e operand_c;            // ALU source C (FMA third operand)
	alu_op_e alu_op;                // base ALU operation
	csr_op_e csr_op;                // CSR read/write/set/clear
	onebit_sig_e csr_use_immediate; // CSR immediate vs register source
	csr_reg_e csr_addr;             // CSR address
	mul_op_e mul_op;                // M-ext multiply/divide operation
	amo_op_e amo_op;                // A-ext atomic operation
	float_op_e float_op;            // F-ext floating-point operation
	roundmode_e roundmode;          // FP rounding mode
	bit_op_e bit_op;                // Zba/Zbb bit manipulation operation
	exec_result_e exec_result;      // execution result source select
	reg_add_e rs1_int;              // integer source register 1
	reg_add_e rs2_int;              // integer source register 2
	reg_add_e rs3_int;              // integer source register 3
	reg_add_e rd_int;               // integer destination register
	reg_add_e rs1_float;            // float source register 1
	reg_add_e rs2_float;            // float source register 2
	reg_add_e rs3_float;            // float source register 3
	reg_add_e rd_float;             // float destination register
	wb_sel_e wb_sel;                // writeback source (EXEC/MEMORY/PC)
	onebit_sig_e ebreak;            // EBREAK instruction
	onebit_sig_e ecall;             // ECALL instruction
  onebit_sig_e mret;              // MRET instruction
  onebit_sig_e sret;              // SRET instruction
} ctrl_bus_e;

endpackage