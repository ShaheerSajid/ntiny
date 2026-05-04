#ifndef GPIO_DEFS_H_
#define GPIO_DEFS_H_

#include "mem_map.h"

/* Phase 2a peripheral standardisation: ntiny GPIO matches sifive,gpio0
 * register layout. Offsets are byte-addresses; index the base pointer
 * as a (uint32_t *) by dividing by 4. */
#define GPIO_INPUT_VAL    0x00
#define GPIO_INPUT_EN     0x04
#define GPIO_OUTPUT_EN    0x08
#define GPIO_OUTPUT_VAL   0x0C
#define GPIO_PUE          0x10  /* RAZ/WI on ntiny */
#define GPIO_DS            0x14  /* RAZ/WI on ntiny */
#define GPIO_RISE_IE      0x18
#define GPIO_RISE_IP      0x1C  /* W1C */
#define GPIO_FALL_IE      0x20
#define GPIO_FALL_IP      0x24  /* W1C */
#define GPIO_HIGH_IE      0x28
#define GPIO_HIGH_IP      0x2C  /* W1C */
#define GPIO_LOW_IE       0x30
#define GPIO_LOW_IP       0x34  /* W1C */
#define GPIO_IOF_EN       0x38  /* RAZ/WI on ntiny */
#define GPIO_IOF_SEL      0x3C  /* RAZ/WI on ntiny */
#define GPIO_OUT_XOR      0x40

#endif
