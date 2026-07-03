#include <stdint.h>
#include "group2_uart_print.h"

#define CTRL_BASE             0x01400000u
#define CTRL_RST_OFFSET       0x004u
#define CTRL_ICN_OFFSET       0x008u
#define CTRL_IRQ_EN_OFFSET    0x010u
#define CTRL_CLK_EN_OFFSET    0x014u

#define GROUP2_OFF_STATUS     0x004u
#define GROUP2_OFF_CONFIG     0x008u

static inline uint32_t mmio_read32(uint32_t addr)
{
  return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint32_t addr, uint32_t value)
{
  *(volatile uint32_t *)addr = value;
}

static void print_reg(const char *name, uint32_t value)
{
  group2_print_str(name);
  group2_print_str("=");
  group2_print_hex32(value);
  group2_print_str("\r\n");
}

static void enable_all_subsystem_slots(void)
{
  mmio_write32(CTRL_BASE + CTRL_CLK_EN_OFFSET, 0x000000ffu);
  mmio_write32(CTRL_BASE + CTRL_IRQ_EN_OFFSET, 0x000000ffu);
  mmio_write32(CTRL_BASE + CTRL_RST_OFFSET,    0x000001ffu);
  mmio_write32(CTRL_BASE + CTRL_ICN_OFFSET,    0x000000ffu);
}

int main(void)
{
  const uint32_t cfg = 0x00084210u;
  int live_windows = 0;

  group2_print_init();
  group2_print_str("\r\nGROUP2 diag test\r\n");

  group2_print_str("before enable\r\n");
  print_reg("RST", mmio_read32(CTRL_BASE + CTRL_RST_OFFSET));
  print_reg("ICN", mmio_read32(CTRL_BASE + CTRL_ICN_OFFSET));
  print_reg("IRQ", mmio_read32(CTRL_BASE + CTRL_IRQ_EN_OFFSET));
  print_reg("CLK", mmio_read32(CTRL_BASE + CTRL_CLK_EN_OFFSET));

  enable_all_subsystem_slots();

  group2_print_str("after enable-all\r\n");
  print_reg("RST", mmio_read32(CTRL_BASE + CTRL_RST_OFFSET));
  print_reg("ICN", mmio_read32(CTRL_BASE + CTRL_ICN_OFFSET));
  print_reg("IRQ", mmio_read32(CTRL_BASE + CTRL_IRQ_EN_OFFSET));
  print_reg("CLK", mmio_read32(CTRL_BASE + CTRL_CLK_EN_OFFSET));

  for (uint32_t i = 0; i < 8u; ++i) {
    uint32_t base = 0x01500000u + (i * 0x00010000u);
    mmio_write32(base + GROUP2_OFF_CONFIG, cfg + i);
  }

  for (uint32_t i = 0; i < 8u; ++i) {
    uint32_t base = 0x01500000u + (i * 0x00010000u);
    uint32_t status = mmio_read32(base + GROUP2_OFF_STATUS);
    uint32_t config = mmio_read32(base + GROUP2_OFF_CONFIG);

    group2_print_str("WIN");
    group2_print_i32((int32_t)i);
    group2_print_str(" base=");
    group2_print_hex32(base);
    group2_print_str(" status=");
    group2_print_hex32(status);
    group2_print_str(" config=");
    group2_print_hex32(config);
    group2_print_str("\r\n");

    if (config == (cfg + i)) {
      live_windows++;
    }
  }

  if (live_windows > 0) {
    group2_print_str("GROUP2 DIAG TEST PASS live_windows=");
    group2_print_i32(live_windows);
    group2_print_str("\r\n");
  } else {
    group2_print_str("GROUP2 DIAG TEST FAIL live_windows=0\r\n");
  }

  while (1) {
  }
}
