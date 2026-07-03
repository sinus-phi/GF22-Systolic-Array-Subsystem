#include <stdint.h>
#include "ss2_sa.h"
#include "ss2_uart_print.h"

static volatile uint32_t trap_seen;
static volatile uint32_t trap_mcause_value;
static volatile uint32_t trap_mtval_value;
static volatile uintptr_t trap_resume_pc;

void ss2_pstrb_trap_handler(void) __attribute__((interrupt("machine"), aligned(4)));

void ss2_pstrb_trap_handler(void)
{
  uint32_t mcause;
  uint32_t mtval;

  asm volatile("csrr %0, mcause" : "=r"(mcause));
  asm volatile("csrr %0, mtval" : "=r"(mtval));

  trap_seen = 1u;
  trap_mcause_value = mcause;
  trap_mtval_value = mtval;

  asm volatile("csrw mepc, %0" :: "r"(trap_resume_pc));
}

static void install_trap_handler(void)
{
  uintptr_t handler = (uintptr_t)&ss2_pstrb_trap_handler;
  asm volatile("csrw mtvec, %0" :: "r"(handler));
}

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {
    asm volatile("nop");
  }
}

static void try_partial_byte_store(uint32_t offset, uint8_t value)
{
  volatile uint8_t *addr = (volatile uint8_t *)(SS2_SA_BASE + offset);
  trap_resume_pc = (uintptr_t)&&resume_after_fault;

  asm volatile(
    ".option push\n"
    ".option norvc\n"
    "sb %[value], 0(%[addr])\n"
    ".option pop\n"
    :
    : [value] "r"(value), [addr] "r"(addr)
    : "memory");

resume_after_fault:
  asm volatile("nop");
}

int main(void)
{
  int errors = 0;
  uint32_t status = 0u;
  uint32_t cfg = ss2_sa_make_config(SS2_SA_DTYPE_INT4,
                                    SS2_SA_DTYPE_INT4,
                                    1u, 1u, 1u, 1u);

  ss2_print_init();
  ss2_print_str("\r\nSS2 PSTRB software test\r\n");

  install_trap_handler();

  ss2_sa_disable();
  short_delay();
  ss2_sa_enable();
  short_delay();
  ss2_sa_soft_reset();

  ss2_sa_write32(SS2_SA_OFF_CONFIG, cfg);
  ss2_print_check_u32("full-word config write readback",
                      cfg,
                      ss2_sa_read32(SS2_SA_OFF_CONFIG),
                      &errors);

  trap_seen = 0u;
  trap_mcause_value = 0u;
  trap_mtval_value = 0u;

  try_partial_byte_store(SS2_SA_OFF_CONFIG, 0x5Au);

  status = ss2_sa_read32(SS2_SA_OFF_STATUS);
  uint32_t error_code = ss2_sa_read32(SS2_SA_OFF_ERROR_CODE);

  ss2_print_str("partial byte store trap_seen=");
  ss2_print_i32((int32_t)trap_seen);
  ss2_print_str(" mcause=");
  ss2_print_hex32(trap_mcause_value);
  ss2_print_str(" mtval=");
  ss2_print_hex32(trap_mtval_value);
  ss2_print_str("\r\n");

  ss2_print_check_u32("partial write sets error sticky",
                      1u,
                      ss2_sa_status_error(status),
                      &errors);
  ss2_print_check_u32("partial write error code",
                      SS2_SA_ERR_UNALIGNED,
                      error_code,
                      &errors);
  ss2_print_check_u32("partial write did not modify config",
                      cfg,
                      ss2_sa_read32(SS2_SA_OFF_CONFIG),
                      &errors);

  ss2_sa_write32(SS2_SA_OFF_CONTROL,
                 SS2_SA_CTRL_CLEAR_ERROR | SS2_SA_CTRL_SOFT_RESET);
  if (ss2_sa_wait_phase(SS2_SA_PH_IDLE, 2000u, &status) != 0) {
    ss2_print_str("[FAIL] idle after clear/reset timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check_u32("error cleared",
                        0u,
                        ss2_sa_status_error(status),
                        &errors);
  }

  if (errors == 0) {
    ss2_print_str("SS2 PSTRB TEST PASS\r\n");
  } else {
    ss2_print_str("SS2 PSTRB TEST FAIL errors=");
    ss2_print_i32(errors);
    ss2_print_str("\r\n");
  }

  while (1) {
  }
}
