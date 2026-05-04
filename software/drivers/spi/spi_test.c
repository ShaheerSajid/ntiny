#include "spi_test.h"
#include "spi_defs.h"
#include "uart.h"
#include "ee_printf.h"
#include <string.h>

static volatile uint32_t *m_spi = (volatile uint32_t *)SPI_BASE_ADDR;

/* Walking-1 register R/W coverage on the SiFive layout. Only the
 * registers that read back exactly what was written are walked here:
 * SCKDIV (12-bit), DELAY0/DELAY1 (32-bit), TXMARK/RXMARK (3-bit). The
 * field-encoded registers (SCKMODE/CSMODE/FMT/IE) are checked with a
 * couple of canonical values rather than a bit walk. */

static int walk_field(uint8_t off, uint32_t bit_count, const char *name)
{
    uint32_t mask = (bit_count >= 32) ? 0xffffffffu : ((1u << bit_count) - 1u);
    for (uint32_t i = 0; i < bit_count; i++) {
        uint32_t v = (1u << i) & mask;
        m_spi[off / 4] = v;
        uint32_t rb = m_spi[off / 4] & mask;
        if (rb != v) {
            ee_printf("SPI %s walk fail at bit %u (wrote %x got %x)\n",
                      name, i, v, rb);
            return 1;
        }
    }
    return 0;
}

int spi_test(void)
{
    /* ── Register R/W coverage ──────────────────────────────── */
    if (walk_field(SPI_SCKDIV, 12, "SCKDIV")) return 1;
    if (walk_field(SPI_DELAY0, 32, "DELAY0")) return 1;
    if (walk_field(SPI_DELAY1, 32, "DELAY1")) return 1;
    if (walk_field(SPI_TXMARK,  3, "TXMARK")) return 1;
    if (walk_field(SPI_RXMARK,  3, "RXMARK")) return 1;

    /* SCKMODE: bits[1:0] */
    for (uint32_t v = 0; v < 4; v++) {
        m_spi[SPI_SCKMODE / 4] = v;
        if ((m_spi[SPI_SCKMODE / 4] & 0x3u) != v) {
            ee_printf("SPI SCKMODE check fail at %u\n", v);
            return 1;
        }
    }

    /* CSMODE: AUTO/HOLD/OFF */
    uint32_t csmode_vals[] = { SPI_CSMODE_AUTO, SPI_CSMODE_HOLD, SPI_CSMODE_OFF };
    for (int i = 0; i < 3; i++) {
        m_spi[SPI_CSMODE / 4] = csmode_vals[i];
        if ((m_spi[SPI_CSMODE / 4] & 0x3u) != csmode_vals[i]) {
            ee_printf("SPI CSMODE check fail at %u\n", csmode_vals[i]);
            return 1;
        }
    }

    /* FMT: len/dir/endian/proto fields */
    uint32_t fmt_v = (8u << SPI_FMT_LEN_SHIFT)
                   | (1u << SPI_FMT_DIR_SHIFT)
                   | (0u << SPI_FMT_ENDIAN_SHIFT)
                   | (0u << SPI_FMT_PROTO_SHIFT);
    m_spi[SPI_FMT / 4] = fmt_v;
    {
        uint32_t rb = m_spi[SPI_FMT / 4];
        uint32_t ref_mask = (0xfu << SPI_FMT_LEN_SHIFT)
                          | (1u   << SPI_FMT_DIR_SHIFT)
                          | (1u   << SPI_FMT_ENDIAN_SHIFT)
                          | (3u   << SPI_FMT_PROTO_SHIFT);
        if ((rb & ref_mask) != (fmt_v & ref_mask)) {
            ee_printf("SPI FMT check fail (wrote %x got %x)\n", fmt_v, rb);
            return 1;
        }
    }

    /* IE: txwm + rxwm */
    m_spi[SPI_IE / 4] = (1u << SPI_IE_TXWM_SHIFT) | (1u << SPI_IE_RXWM_SHIFT);
    if ((m_spi[SPI_IE / 4] & 0x3u) != 0x3u) {
        uart_puts("SPI IE check fail\n");
        return 1;
    }
    m_spi[SPI_IE / 4] = 0u;

    /* CSDEF: per upstream driver probe sequence (writes 0xffffffffU,
     * reads back to count CS lines). On ntiny only bit 0 sticks. */
    m_spi[SPI_CSDEF / 4] = 0xffffffffu;
    if ((m_spi[SPI_CSDEF / 4] & 0xffffffffu) != 0x1u) {
        ee_printf("SPI CSDEF cs-bits probe fail (got %x, expected 0x1)\n",
                  m_spi[SPI_CSDEF / 4]);
        return 1;
    }
    m_spi[SPI_CSDEF / 4] = 1u;   /* restore default */

    /* ── Functional loopback (TB wires MOSI→MISO) ─────────────
     * The simulation testbench shorts mosi_o back to miso_i, so each
     * transmitted byte returns in the RX FIFO. */
    spi_init(0, 0, 24);
    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_HOLD;

    const char *msg = "ntiny";
    for (size_t i = 0; i < strlen(msg); i++) {
        uint8_t got = spi_sendrecv((uint8_t)msg[i]);
        if (got != (uint8_t)msg[i]) {
            ee_printf("SPI loopback mismatch at %u: sent %x got %x\n",
                      (unsigned)i, (uint8_t)msg[i], got);
            return 1;
        }
    }

    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_OFF;
    return 0;
}

/* Legacy entry points kept for callers that still invoke them; they
 * exercise the same spi_writeblock path as the main test. */
void spi_write_test(void)
{
    spi_init(0, 0, 24);
    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_HOLD;
    spi_writeblock("ntiny is alive...\n");
    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_OFF;
}

void spi_read_test(void)
{
    uint8_t buf[8] = {0};
    spi_init(0, 0, 24);
    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_HOLD;
    spi_readblock(buf, sizeof(buf));
    m_spi[SPI_CSMODE / 4] = SPI_CSMODE_OFF;
}
