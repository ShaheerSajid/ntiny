// ntiny RISC-V core configuration for riscv-dv
// RV32IMC + Sv32 MMU + M/S/U modes + PMP

// XLEN
parameter int XLEN = 32;

// Sv32 virtual memory
parameter satp_mode_t SATP_MODE = SV32;

// Supported privilege modes
privileged_mode_t supported_privileged_mode[] = {MACHINE_MODE, SUPERVISOR_MODE, USER_MODE};

// Unsupported instructions (none for base IMC)
riscv_instr_name_t unsupported_instr[];

// ISA supported by the processor
riscv_instr_group_t supported_isa[$] = {RV32I, RV32M, RV32A, RV32F, RV32C};

// Interrupt mode support
mtvec_mode_t supported_interrupt_mode[$] = {DIRECT, VECTORED};

// Number of interrupt vectors
int max_interrupt_vector_num = 16;

// PMP support
bit support_pmp = 1;

// Enhanced PMP
bit support_epmp = 0;

// Debug mode support
bit support_debug_mode = 0;

// Delegate trap to user mode
bit support_umode_trap = 0;

// SFENCE.VMA support
bit support_sfence = 1;

// Unaligned load/store (hardware misalign support)
bit support_unaligned_load_store = 1'b1;

// GPR setting
parameter int NUM_FLOAT_GPR = 32;
parameter int NUM_GPR = 32;
parameter int NUM_VEC_GPR = 32;

// Vector extension
parameter int VECTOR_EXTENSION_ENABLE = 0;
parameter int VLEN = 512;
parameter int ELEN = 32;
parameter int SELEN = 8;
parameter int VELEN = int'($ln(ELEN)/$ln(2)) - 3;
parameter int MAX_LMUL = 8;

// Multi-harts
parameter int NUM_HARTS = 1;

// Implemented privileged CSRs
`ifdef DSIM
privileged_reg_t implemented_csr[] = {
`else
const privileged_reg_t implemented_csr[] = {
`endif
    // Machine mode CSRs
    MVENDORID,
    MARCHID,
    MIMPID,
    MHARTID,
    MSTATUS,
    MISA,
    MIE,
    MTVEC,
    MCOUNTEREN,
    MSCRATCH,
    MEPC,
    MCAUSE,
    MTVAL,
    MIP,
    MEDELEG,
    MIDELEG,
    // Supervisor mode CSRs
    SSTATUS,
    SIE,
    STVEC,
    SCOUNTEREN,
    SSCRATCH,
    SEPC,
    SCAUSE,
    STVAL,
    SIP,
    SATP
};

// Custom CSRs
bit [11:0] custom_csr[] = {
};

// Implemented interrupts
`ifdef DSIM
interrupt_cause_t implemented_interrupt[] = {
`else
const interrupt_cause_t implemented_interrupt[] = {
`endif
    M_SOFTWARE_INTR,
    M_TIMER_INTR,
    M_EXTERNAL_INTR,
    S_SOFTWARE_INTR,
    S_TIMER_INTR,
    S_EXTERNAL_INTR
};

// Implemented exceptions
`ifdef DSIM
exception_cause_t implemented_exception[] = {
`else
const exception_cause_t implemented_exception[] = {
`endif
    INSTRUCTION_ACCESS_FAULT,
    ILLEGAL_INSTRUCTION,
    BREAKPOINT,
    LOAD_ADDRESS_MISALIGNED,
    LOAD_ACCESS_FAULT,
    STORE_AMO_ADDRESS_MISALIGNED,
    STORE_AMO_ACCESS_FAULT,
    ECALL_UMODE,
    ECALL_SMODE,
    ECALL_MMODE,
    INSTRUCTION_PAGE_FAULT,
    LOAD_PAGE_FAULT,
    STORE_AMO_PAGE_FAULT
};
