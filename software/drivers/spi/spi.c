#include "spi.h"
#include "spi_defs.h"

//-----------------------------------------------------------------
// Locals
//-----------------------------------------------------------------
static volatile uint32_t *m_spi;


//-----------------------------------------------------------------
// spi_set_sck_ratio: setting value of clock ratio
//-----------------------------------------------------------------
void spi_set_sck_ratio (uint8_t ratio)
{
    m_spi[SPI_CLK_RATIO/4] = ratio;
}

//-----------------------------------------------------------------
// spi_init: Initialise SPI master
//-----------------------------------------------------------------
void spi_init(int cpol, int cpha, int lsb_first )           
{
    uint32_t cfg = 0;
    m_spi = (volatile uint32_t *)SPI_BASE_ADDR;

    cfg += (1 << SPI_CR_SPE_SHIFT);
    cfg += (1 << SPI_CR_MASTER_SHIFT);
    cfg += (cpol << SPI_CR_CPOL_SHIFT);
    cfg += (cpha << SPI_CR_CPHA_SHIFT);
    cfg += (1 << SPI_CR_MANUAL_SS_SHIFT);
    cfg += (lsb_first << SPI_CR_LSB_FIRST_SHIFT);

    m_spi[SPI_CR/4]  = cfg;
   // m_spi[SPI_CR/4]  = cfg;
    
    m_spi[SPI_SSR/4] = ~0;
    //   m_spi[SPI_SSR/4] = ~0;

    // Soft reset
    m_spi[SPI_SRR/4] = 0x0000000A;

 
}



//-----------------------------------------------------------------
// spi_cs: Set chip select
//-----------------------------------------------------------------
void spi_cs(uint32_t value)
{
   
    m_spi[SPI_SSR/4] = ~value;
  
}

//-----------------------------------------------------------------
// spi_sendrecv: Send or receive a character
//-----------------------------------------------------------------
uint8_t spi_sendrecv(uint8_t data)
{
    m_spi[SPI_DTR/4] = data;
    __asm("nop");
    __asm("nop");
    __asm("nop");
    while (!(m_spi[SPI_SR/4] & (1 << SPI_SR_TX_EMPTY_SHIFT)))
        {
                __asm("nop");
        }

    return (uint8_t)m_spi[SPI_DRR/4];
}

//-----------------------------------------------------------------
// spi_readblock: Read a block of data from a device
//-----------------------------------------------------------------
void spi_readblock(uint8_t *ptr, int length)
{
    int i;

    for (i=0;i<length;i++)
        *ptr++ = spi_sendrecv(0xFF);

}

//-----------------------------------------------------------------
// spi_writeblock: Write a block of data to a device
//-----------------------------------------------------------------
void spi_writeblock(char *ptr)
{
    

    while (*ptr != 0)
        spi_sendrecv(*ptr++);
 
}
