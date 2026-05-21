#ifndef INIT_H
#define INIT_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Disable S-Mode supervisor-level interrupts (clears the SIE bit in sstatus).
 *        Safely call this within your application to enter critical sections 
 *        prior to scheduler launch.
 */
void int_disable(void);

/**
 * @brief Enable S-Mode supervisor-level interrupts (sets the SIE bit in sstatus).
 */
void int_enable(void);

/**
 * @brief Low-level boot entry point anchored at 0x80400000. 
 *        Executed immediately after OpenSBI passes off control.
 */
void _init(void) __attribute__((section(".init"), naked));

/**
 * @brief Primary hardware reset handler responsible for zeroing architectural 
 *        registers, establishing stack topologies, initializing BSS segments,
 *        and branching to main().
 */
void RESET_HANDLER(void) __attribute__((section(".RESET_HANDLER"), naked));

#ifdef __cplusplus
}
#endif

#endif /* INIT_H */