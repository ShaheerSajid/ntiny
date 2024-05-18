#include "spi_test.h"
#include "spi_defs.h"
#include "timer.h"
#include "uart.h"
#include "ee_printf.h"
#include <string.h>

static volatile uint32_t *m_spi = (volatile uint32_t *)SPI_BASE_ADDR;

//-----------------------------------------------------------------------
// spi_write_read_test: testing of spi single byte read write function
//-----------------------------------------------------------------------
	void spi_write_test ()
	 {
		spi_init(0,0,0);
		spi_set_sck_ratio(50);
		spi_cs (0x0);
		//uart_puts("Hi slave.. are..Hi slave.. are.\n");
		//uart_puts("sending data to spi..\n");
		spi_cs (0x01);
		/*  char* message = "Hi I am Master\n";
		spi_writeblock (message); */
		//spi_sendrecv('S');
		spi_writeblock ("Ntiny is alive...\n");
		spi_cs (0x0);
		//uart_putc(spi_sendrecv('\n'));
		delay_ms(500); // delay of 1 second 
	}
//-----------------------------------------------------------------------
// spi_write_read_test: testing of spi single byte read write function
//-----------------------------------------------------------------------
	void spi_read_test ()
	 {
		spi_init(0,0,0);
		spi_set_sck_ratio(50);
		spi_cs (0x0);
		//uart_puts("Hi slave.. are..Hi slave.. are.\n");
		//uart_puts("sending data to spi..\n");
		char *message;
		spi_cs (0x01);
		/*  char* message = "Hi I am Master\n";
		spi_writeblock (message); */
		//spi_sendrecv('S');
		spi_readblock (message,10);
		spi_cs (0x0);
		uart_puts(message);
		uart_puts("\n");
		//uart_putc(spi_sendrecv('\n'));
	}


//-----------------------------------------------------------------------
// spi_test: testing of spi 
//-----------------------------------------------------------------------

int spi_test()
{
	// Register read/write test
	// if uart is working fine we can peak and poke every registers of SPI.
	// test to check if writing and reading to the registers is correctly happening. 

	for (int i = 0; i<16; i++) // setting every single bits of the SPI_CLK_RATIO register and conforming it
	{
		poke_reg(m_spi,SPI_CLK_RATIO,1<<i);
		if (peak_reg(m_spi,SPI_CLK_RATIO)!= (1<<i))
		{
			uart_puts("SPI clock ratio register is not working correctly\n");
			return 1;
		}
	}
	
	uint32_t register_list[] = {SPI_DGIER,SPI_IPISR,SPI_IPIER,SPI_SRR,SPI_CR,SPI_SR,SPI_DTR,SPI_SSR};
	
	for ( int registers = 0; registers <8; registers++) // iterating through all 5 registers of I2C
	{
		for (int i = 0; i<8; i++) // setting every single bits of the register and conforming it
		{
			poke_reg(m_spi,register_list[registers],1<<i);
			
			if (peak_reg(m_spi,register_list[registers])!= (1<<i))
				{
					ee_printf ("SPI register at address map %d is not working correctly\n",register_list[registers]);
					return 1;
				}
		}
	}



	// fucntionality test for SPI 
	// connecting two slave device. Device connected to SS[0] has name "SS[0]"
	// and similarly device connected to SS[1] has the name "SS[1]"
	// communication between the slave and master is verified by asking slave names and check the names are correct. 
	char *message ="What is your id?";


	spi_init(0,0,0);
    spi_set_sck_ratio(50);
	spi_writeblock(message);
	char *recv_message;
	spi_readblock(recv_message,strlen(message));
	if (strcmp(recv_message,message))
	{
		return 1;
	}

	return 0;
}

