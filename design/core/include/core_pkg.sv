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
	MISC_MEM= 7'b0001111,   // FENCE / FENCE.I
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
typedef enum logic[5:0] {
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
	// Zbc — carry-less multiply
	CLMUL,
	CLMULH,
	CLMULR,
	// Zbs — single-bit ops (reg + imm variants share datapath; the
	// reg/imm distinction is via the `b` operand source in the ALU mux)
	BCLR,
	BCLRI,
	BEXT,
	BEXTI,
	BINV,
	BINVI,
	BSET,
	BSETI,
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
	SEED			= 12'h015,  // Zkr: entropy source CSR
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
	MENVCFG			= 12'h30A,
	MENVCFGH		= 12'h31A,
	MCONFIGPTR		= 12'hF15,
	// PMP (not implemented — reads as zero, writes ignored)
	PMPCFG0			= 12'h3A0,
	PMPCFG1			= 12'h3A1,
	PMPCFG2			= 12'h3A2,
	PMPCFG3			= 12'h3A3,
	PMPADDR0		= 12'h3B0,
	PMPADDR1		= 12'h3B1,
	PMPADDR2		= 12'h3B2,
	PMPADDR3		= 12'h3B3,
	PMPADDR4		= 12'h3B4,
	PMPADDR5		= 12'h3B5,
	PMPADDR6		= 12'h3B6,
	PMPADDR7		= 12'h3B7,
	PMPADDR8		= 12'h3B8,
	PMPADDR9		= 12'h3B9,
	PMPADDR10		= 12'h3BA,
	PMPADDR11		= 12'h3BB,
	PMPADDR12		= 12'h3BC,
	PMPADDR13		= 12'h3BD,
	PMPADDR14		= 12'h3BE,
	PMPADDR15		= 12'h3BF,
	DCSR			= 12'h7b0,
	DPC 			= 12'h7b1,
	//Supervisor Mode
	SSTATUS     	= 12'h100,
   	SIE         	= 12'h104,
    STVEC       	= 12'h105,
    SCOUNTEREN  	= 12'h106,
    SENVCFG			= 12'h10A,
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

// Redirect-arbiter kind enum (fetch revamp Phase 1).
// Single source of truth for "why is the next fetch going somewhere other
// than pc+4". Mirrors pc_sel_e but with explicit MRET vs SRET distinction
// removed (the arbiter resolves which xPC to use internally) and a RESET
// kind for completeness. See docs/fetch_revamp_plan.md §4.1.
typedef enum logic [2:0] {
	RDR_NONE   = 3'd0,
	RDR_RESET  = 3'd1,
	RDR_DEBUG  = 3'd2,
	RDR_TRAP   = 3'd3,
	RDR_XRET   = 3'd4,
	RDR_BRANCH = 3'd5
} redirect_kind_e;

// Per-instruction "what to do at writeback" tag (Phase 4 trap revamp).
// Set at the detection stage of each fault/system instruction and
// propagated through the IE/IMEM/IWB register walls inside ctrl_bus_e.
// Resolved atomically at IWB by wb_trap_unit, which performs the
// pipeline flush, CSR side effects, priv switch and PC redirect.
//   WB_NONE  : normal retirement
//   WB_TRAP  : take a synchronous trap (cause/tval already known at tag time)
//   WB_XRET  : commit mret/sret (read mepc/sepc, switch priv, redirect)
//   WB_DRET  : commit dret (read dpc, exit debug mode, redirect)
typedef enum logic [1:0] {
	WB_NONE = 2'd0,
	WB_TRAP = 2'd1,
	WB_XRET = 2'd2,
	WB_DRET = 2'd3
} wb_event_e;

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
  onebit_sig_e sfence_vma;        // SFENCE.VMA instruction
  onebit_sig_e fence_i;           // FENCE.I instruction (flush I-cache)
  onebit_sig_e predicted_taken;   // BPU: was this branch predicted taken?
  // ── Phase 4 trap revamp: per-instruction WB event tag ──
  // Detected at decode/IF/IE depending on the source, propagated through
  // the IE/IMEM/IWB register walls, resolved atomically by wb_trap_unit.
  wb_event_e   wb_event;          // NONE / TRAP / XRET / DRET
  logic [4:0]  wb_cause;           // mcause to write (only meaningful when wb_event==WB_TRAP)
  logic [31:0] wb_tval;            // mtval to write (only meaningful when wb_event==WB_TRAP)
} ctrl_bus_e;

// NOP control bundle — used as pipeline flush/reset value.
// Defined once here so adding a new field only needs one edit.
function automatic ctrl_bus_e CTRL_BUS_NOP();
	CTRL_BUS_NOP.inst_type       = NO_INS;
	CTRL_BUS_NOP.br_cond         = NO_CONDITION;
	CTRL_BUS_NOP.load_store_width= NO_WIDTH;
	CTRL_BUS_NOP.mem_unsigned    = FALSE;
	CTRL_BUS_NOP.imm_sel         = NO_IMM;
	CTRL_BUS_NOP.mem_op          = NO_MEM_OP;
	CTRL_BUS_NOP.operand_a       = NO_OPERAND;
	CTRL_BUS_NOP.operand_b       = NO_OPERAND;
	CTRL_BUS_NOP.operand_c       = NO_OPERAND;
	CTRL_BUS_NOP.alu_op          = NO_ALU_OP;
	CTRL_BUS_NOP.csr_op          = NO_CSR_OP;
	CTRL_BUS_NOP.csr_use_immediate = FALSE;
	CTRL_BUS_NOP.csr_addr        = NO_CSR_REG;
	CTRL_BUS_NOP.mul_op          = NO_MUL_OP;
	CTRL_BUS_NOP.amo_op          = NO_AMO_OP;
	CTRL_BUS_NOP.bit_op          = NO_BIT_OP;
	CTRL_BUS_NOP.float_op        = NO_FP_OP;
	CTRL_BUS_NOP.roundmode       = RNE;
	CTRL_BUS_NOP.exec_result     = NO_EX_RES;
	CTRL_BUS_NOP.rs1_int         = NO_REG;
	CTRL_BUS_NOP.rs2_int         = NO_REG;
	CTRL_BUS_NOP.rs3_int         = NO_REG;
	CTRL_BUS_NOP.rd_int          = NO_REG;
	CTRL_BUS_NOP.rs1_float       = NO_REG;
	CTRL_BUS_NOP.rs2_float       = NO_REG;
	CTRL_BUS_NOP.rs3_float       = NO_REG;
	CTRL_BUS_NOP.rd_float        = NO_REG;
	CTRL_BUS_NOP.wb_sel          = NO_WB;
	CTRL_BUS_NOP.ebreak          = FALSE;
	CTRL_BUS_NOP.ecall           = FALSE;
	CTRL_BUS_NOP.mret            = FALSE;
	CTRL_BUS_NOP.sret            = FALSE;
	CTRL_BUS_NOP.sfence_vma      = FALSE;
	CTRL_BUS_NOP.fence_i         = FALSE;
	CTRL_BUS_NOP.predicted_taken = FALSE;
	CTRL_BUS_NOP.wb_event        = WB_NONE;
	CTRL_BUS_NOP.wb_cause        = 5'd0;
	CTRL_BUS_NOP.wb_tval         = 32'd0;
endfunction

endpackage