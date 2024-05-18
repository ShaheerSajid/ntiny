#include "i2c.h"
#include "i2c_defs.h"

static volatile uint32_t *m_I2C;
///////////////////////////////////////////////////
// Initialize I2C module
///////////////////////////////////////////////////
void I2C_init ( uint32_t i2c_freq)
{ 
	  uint32_t clock_prescaler = (50000000/(5*i2c_freq)) - 1 ;
	  uint32_t ctrl_reg = 0;
	 m_I2C =	(volatile uint32_t *)BASE_ADDR;
	 // Reset
	 m_I2C[REG_CTRL] = 0;
	
	 
	 m_I2C[REG_CMD] = 0;
	 ctrl_reg		= 0x80;
	 //clock_prescaler = 0x3ff;
	 m_I2C[REG_CLK_PRESCALER] = clock_prescaler;
	
	m_I2C[REG_CTRL] = ctrl_reg;
	
}

///////////////////////////////////////////////////
// Close I2C module
///////////////////////////////////////////////////

void I2C_close (void)
{	
	m_I2C[REG_CMD] = 0x0;

}

///////////////////////////////////////////////////
// Start I2C transaction
///////////////////////////////////////////////////

void I2C_start (uint32_t slave_addr, uint32_t read )
{
	//uart_puts("entered I2C start ..\n");
	m_I2C[REG_TX] = ((slave_addr<<1)|(0x01&read));
	m_I2C[REG_CMD] = 0x90;	
	__asm("nop");
	__asm("nop");
	
	while ( (m_I2C[REG_STATUS]&0x02)){
	}	

}

///////////////////////////////////////////////////
// Write I2C data for transaction
///////////////////////////////////////////////////

void I2C_write(uint8_t data,uint8_t last )
{
	// transmit data;
	m_I2C[REG_TX] = data;

	if (last)
	{
		m_I2C[REG_CMD] = 0x50;
	}
	else 
	{
		m_I2C[REG_CMD] = 0x10;
	}
	__asm("nop");
	__asm("nop");
	while ( (m_I2C[REG_STATUS]&0x02))
	{
		
	}
	
}

///////////////////////////////////////////////////
// Read I2C data from transaction
///////////////////////////////////////////////////

int I2C_read(uint8_t last  )
{
	if (last)
	{
		m_I2C[REG_CMD] = 0x68;
	}
	else 
	{
		m_I2C[REG_CMD] = 0x20;
	}
	__asm("nop");
	__asm("nop");
	while ( (m_I2C[REG_STATUS]&0x02))
	{

	}

	return 	m_I2C[REG_RX];
	
}

