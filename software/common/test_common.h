#ifndef __TEST_H__
#define __TEST_H__
#include <stdint.h>

uint32_t peak_reg(volatile uint32_t* base_addr,uint8_t  reg_addr);
void poke_reg(volatile uint32_t* base_addr,uint8_t reg_addr, uint32_t reg_value );


#endif