#include <stdint.h>
#include "group2_sa.h"
#include "group2_uart_print.h"

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {
    asm volatile("nop");
  }
}

int main(void)
{
  int errors = 0;
  uint32_t status = 0u;

  group2_print_init();
  group2_print_str("\r\nGROUP2 smoke test\r\n");

  group2_sa_disable();
  short_delay();
  group2_sa_enable();
  short_delay();
  group2_sa_soft_reset();

  status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
  group2_print_check_u32("phase after enable/reset",
                         GROUP2_SA_PH_IDLE,
                         group2_sa_status_phase(status),
                         &errors);
  group2_print_check_u32("error clear after reset",
                         0u,
                         group2_sa_status_error(status),
                         &errors);

  uint32_t cfg = group2_sa_make_config(GROUP2_SA_DTYPE_INT4,
                                       GROUP2_SA_DTYPE_INT4,
                                       1u, 1u, 1u, 1u);
  group2_sa_write32(GROUP2_SA_OFF_CONFIG, cfg);
  group2_print_check_u32("config readback", cfg,
                         group2_sa_read32(GROUP2_SA_OFF_CONFIG), &errors);

  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_LOAD_WEIGHTS);
  if (group2_sa_wait_phase(GROUP2_SA_PH_LOAD_WEIGHTS, 2000u, &status) != 0) {
    group2_print_str("[FAIL] load weight phase timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  } else {
    group2_print_check("load weight phase reached", 1);
  }

  const int32_t weight_col0[1] = {3};
  group2_sa_stream_weight_vector(weight_col0, GROUP2_SA_DTYPE_INT4, 1u);

  if (group2_sa_wait_phase(GROUP2_SA_PH_BATCH_COMPUTE, 4000u, &status) != 0) {
    group2_print_str("[FAIL] compute phase timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  } else {
    group2_print_check_u32("weights valid after load",
                           1u,
                           group2_sa_status_weights_valid(status),
                           &errors);
  }

  const int32_t act_row0[1] = {4};
  group2_sa_stream_activation_vector(act_row0, GROUP2_SA_DTYPE_INT4, 1u);

  if (group2_sa_wait_output_valid(8000u, &status) != 0) {
    group2_print_str("[FAIL] output valid timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  } else {
    group2_print_check_u32("output word count",
                           2u,
                           group2_sa_status_output_words(status),
                           &errors);
    int32_t got = (int32_t)group2_sa_read_output_elem(0u, 0u, 1u);
    group2_print_check_i32("1x1 output 4*3", 12, got, &errors);
  }

  group2_sa_release_output();
  if (group2_sa_wait_phase(GROUP2_SA_PH_IDLE, 4000u, &status) != 0) {
    group2_print_str("[FAIL] idle after release timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  } else {
    group2_print_check("idle after release", 1);
  }

  if (errors == 0) {
    group2_print_str("GROUP2 SMOKE TEST PASS\r\n");
  } else {
    group2_print_str("GROUP2 SMOKE TEST FAIL errors=");
    group2_print_i32(errors);
    group2_print_str("\r\n");
  }

  while (1) {
  }
}
