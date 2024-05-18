#include "test.h"



uint32_t peak_reg(volatile uint32_t* base_addr,uint8_t  reg_addr)
{
    uint32_t value;
	// read the value of reg_addr register of the Peripheral mapped at base_addr
	value = base_addr[reg_addr] ;
	return value;   
}

void poke_reg(volatile uint32_t* base_addr,uint8_t reg_addr, uint32_t reg_value )
{
	// assign reg_value as value of reg_addr 
	base_addr[reg_addr] = reg_value;
}