#include "spi.h"
#include "spi_defs.h"

static volatile uint32_t *m_spi;

void spi_init(int cpol, int cpha, int sckdiv)
{
    m_spi = (volatile uint32_t *)SPI_BASE_ADDR;

    m_spi[SPI_SCKDIV  / 4] = (uint32_t)sckdiv & SPI_SCKDIV_DIV_MASK;
    m_spi[SPI_SCKMODE / 4] = (((uint32_t)cpol & 1u) << SPI_SCKMODE_CPOL_SHIFT)
                           | (((uint32_t)cpha & 1u) << SPI_SCKMODE_CPHA_SHIFT);
    m_spi[SPI_CSID    / 4] = 0u;
    m_spi[SPI_CSDEF   / 4] = 1u;                  /* CS0 default high (active-low) */
    m_spi[SPI_CSMODE  / 4] = SPI_CSMODE_OFF;      /* start with CS deasserted */
    m_spi[SPI_FMT     / 4] = (8u << SPI_FMT_LEN_SHIFT);  /* 8-bit MSB-first single-proto */
    m_spi[SPI_TXMARK  / 4] = 1u;
    m_spi[SPI_RXMARK  / 4] = 0u;
    m_spi[SPI_IE      / 4] = 0u;
}

void spi_set_sck_ratio(uint8_t ratio)
{
    m_spi[SPI_SCKDIV / 4] = ratio;
}

void spi_cs(uint32_t value)
{
    m_spi[SPI_CSMODE / 4] = value ? SPI_CSMODE_HOLD : SPI_CSMODE_OFF;
}

uint8_t spi_sendrecv(uint8_t data)
{
    while (m_spi[SPI_TXDATA / 4] & (1u << SPI_TXDATA_FULL_SHIFT))
        ;
    m_spi[SPI_TXDATA / 4] = data;

    uint32_t rx;
    do {
        rx = m_spi[SPI_RXDATA / 4];
    } while (rx & (1u << SPI_RXDATA_EMPTY_SHIFT));

    return (uint8_t)(rx & 0xffu);
}

void spi_readblock(uint8_t *ptr, int length)
{
    for (int i = 0; i < length; i++)
        *ptr++ = spi_sendrecv(0xff);
}

void spi_writeblock(const char *ptr)
{
    while (*ptr != 0)
        spi_sendrecv((uint8_t)*ptr++);
}
