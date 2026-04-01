#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

// ntiny tohost address: bus write to 0x0F000000 triggers test completion in testbench.
// No backing memory at this address — testbench monitors dbus writes.
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

// RVMODEL_HALT: write 1 to tohost to signal test completion
#define RVMODEL_HALT                                                    \
  li x1, 1;                                                             \
  write_tohost:                                                         \
    sw x1, tohost, t5;                                                  \
    j write_tohost;

#define RVMODEL_BOOT

// Signature data region — placed in RAM by linker
// NOTE: RVMODEL_DATA_SECTION must come AFTER end_signature (not before begin_signature).
// The vm_sv32 tests do `.align 12` immediately before RVMODEL_DATA_BEGIN to ensure
// begin_signature is 4KB-page-aligned. Inserting begin_regstate/end_regstate before
// begin_signature breaks that alignment, causing s11 SREG writes from VERIFICATION_RWX
// to land inside the sig capture range (overwriting the end canary). Spike's model_test.h
// places RVMODEL_DATA_SECTION in RVMODEL_DATA_END — we match that here.
#define RVMODEL_DATA_BEGIN                                              \
  .align 4;                                                             \
  .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .align 4;                                                             \
  .global end_signature; end_signature:                                 \
  RVMODEL_DATA_SECTION

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _COMPLIANCE_MODEL_H
