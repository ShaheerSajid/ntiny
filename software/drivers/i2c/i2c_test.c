#include "i2c_test.h"
#include "timer.h"
#include "uart.h"
#include "ee_printf.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


volatile uint32_t *m_i2c = (volatile uint32_t *)BASE_ADDR;

int i2c_test()
{
	// Register read and write tests 
	// if uart is working fine we can peak and poke every registers of I2C.
	// test to check if writing and reading to the registers is correctly happening. 

	/* Phase 2c: prescaler is split into PRELO/PREHI 8-bit halves (each
	 * RW). Walk a single bit through each. */
	uint32_t pres_list[] = {REG_PRELO, REG_PREHI};
	for (int p = 0; p < 2; p++)
		for (int i = 0; i < 8; i++) {
			poke_reg(m_i2c, pres_list[p], 1u << i);
			if (peak_reg(m_i2c, pres_list[p]) != (1u << i)) {
				uart_puts("I2C prescaler register is not working correctly\n");
				return 1;
			}
		}

	/* CTRL is the only other register where reads return the last
	 * written byte (DATA reads return rx, CMDSTAT reads return status —
	 * neither matches the written value, so peek/poke isn't applicable). */
	for (int i = 0; i < 8; i++) {
		poke_reg(m_i2c, REG_CTRL, 1u << i);
		if (peak_reg(m_i2c, REG_CTRL) != (1u << i)) {
			ee_printf("I2C CTRL register is not working correctly\n");
			return 1;
		}
	}
	I2C_close();


	// fucntionality test for I2C 
	// connecting two slave device. Device with device address 0 has name "slave_0"
	// and similarly Device with device address has the name "slave_1"
	// communication between the slave and master is verified by asking slave names and 
	// checking that the recieved names are correct.

	uint8_t slave0 = 0;
	char* message = "What is your id?";
	char* recv_message;
	uint8_t slave1 = 1;

	////// inititialize I2C 
	I2C_init (400000);
	// send message to slave 0
	I2C_start (slave0, 0);
	send_string(message);
	I2C_start (slave0, 1);
	read_string(recv_message);
	if (strcmp(recv_message,message))
	{
		return 1;
	}

	// send message to slave 1
	I2C_start (slave1, 0);
	send_string(message);
	I2C_start (slave1, 1);
	read_string(recv_message);
	if (strcmp(recv_message,message))
	{
		return 1;
	}

	return 0; // test completed sucessfully
}

void send_string(char * data)
{
	int i;
	for ( i =0 ; i<(strlen(data)-1); i++)
	{
		I2C_write(data[i],0);
	}
	I2C_write(data[i],1);
	
}

void read_string(char *data)
{
	int i;
	for ( i =0 ; i<5; i++)
	{
		data[i]=I2C_read(0);
	}
	data[i] = I2C_read(1);
}


void i2c_read_test ()
{
		I2C_init (400000);
		//I2C_start(0x9,0);
		//I2C_write('S',0);
		I2C_start(0x9,1);
		uint32_t x = I2C_read(0);
		uint32_t y = I2C_read(1);
		/*
		uint32_t temp;
		for (int i = 1; i<=32; i++)
		{
			temp = x&(1<<(32-i));
			if ( temp )
			{
				uart_putc('1');		
			}
			else 
				uart_putc('0');	
				
		}
	 	uart_puts ("\n");
	 	*/

		uart_putc(x);
		uart_putc(y);
		
		uart_puts ("\n");

		delay_ms(1000);

}



 