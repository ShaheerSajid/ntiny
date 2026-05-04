#ifndef __I2C__DEFS_H__
#define __I2C__DEFS_H__

#include "mem_map.h"

/* Phase 2c peripheral standardisation: ntiny I2C matches the upstream
 * Linux i2c-ocores driver (drivers/i2c/busses/i2c-ocores.c, compatible
 * "opencores,i2c-ocores"). reg-shift=2, reg-io-width=4. Word indices
 * (= byte addr / 4):
 *   0 prelo  : low 8 bits of clock prescaler
 *   1 prehi  : high 8 bits
 *   2 ctrl   : bit 7 = i2c-enable, bit 6 = interrupt-enable
 *   3 data   : write = tx data, read = rx data (aliased)
 *   4 cmdstat: write = cmd reg, read = status reg (aliased) */

#define REG_PRELO        0x00
#define REG_PREHI        0x01
#define REG_CTRL         0x02
#define REG_DATA         0x03
#define REG_CMDSTAT      0x04

/* Convenience aliases for the historical names the bare-metal driver
 * uses (tx/rx alias the data register, cmd/status alias cmdstat). */
#define REG_TX           REG_DATA
#define REG_RX           REG_DATA
#define REG_CMD          REG_CMDSTAT
#define REG_STATUS       REG_CMDSTAT

#endif
