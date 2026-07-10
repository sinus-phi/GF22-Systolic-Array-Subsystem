#include <stdint.h>
#include "group2_sa.h"
#include "group2_uart_print.h"

int main(void)
{
  int errors = 0;

  group2_print_init();
  group2_print_str("\r\nGROUP2 final ABI diagnostic\r\n");
  group2_sa_enable();
  group2_sa_soft_reset();

  group2_print_check_u32("VERSION", 0x00010000u,
                         group2_sa_read32(GROUP2_SA_OFF_VERSION), &errors);

  uint32_t capability = group2_sa_read32(GROUP2_SA_OFF_CAPABILITY);
  group2_print_check_u32("dtype mask", 0x7u, capability & 0xFu, &errors);
  group2_print_check_u32("array height", 8u, (capability >> 4) & 0xFu, &errors);
  group2_print_check_u32("array width", 16u, (capability >> 8) & 0x1Fu, &errors);
  group2_print_check_u32("max M", 32u, (capability >> 13) & 0x3Fu, &errors);

  uint32_t status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
  group2_print_check_u32("idle phase", GROUP2_SA_PH_IDLE,
                         group2_sa_status_phase(status), &errors);

  if (errors == 0) {
    group2_print_str("GROUP2 DIAG TEST PASS\r\n");
  } else {
    group2_print_str("GROUP2 DIAG TEST FAIL errors=");
    group2_print_i32(errors);
    group2_print_str("\r\n");
  }

  while (1) {
  }
}
