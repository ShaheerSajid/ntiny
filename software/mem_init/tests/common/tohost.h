#ifndef TOHOST_H
#define TOHOST_H

#include <stdint.h>

// Tohost address — monitored by the testbench for test completion.
// Write 1 for PASS, any other non-zero value for FAIL.
#define TOHOST (*(volatile uint32_t *)0x0F000000)

static inline void tohost_pass(void) {
    TOHOST = 1;
    while (1); // should not reach here
}

static inline void tohost_fail(uint32_t code) {
    TOHOST = (code == 0) ? 2 : code; // ensure non-zero, non-1
    while (1);
}

#endif
