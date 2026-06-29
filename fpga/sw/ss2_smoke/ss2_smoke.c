#include <stdint.h>
#include "ss2_sa.h"
#include "ss2_uart_print.h"

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

  ss2_print_init();
  ss2_print_str("\r\nSS2 smoke test\r\n");

  ss2_sa_disable();
  short_delay();
  ss2_sa_enable();
  short_delay();
  ss2_sa_soft_reset();

  status = ss2_sa_read32(SS2_SA_OFF_STATUS);
  ss2_print_check_u32("phase after enable/reset",
                      SS2_SA_PH_IDLE,
                      ss2_sa_status_phase(status),
                      &errors);
  ss2_print_check_u32("error clear after reset",
                      0u,
                      ss2_sa_status_error(status),
                      &errors);

  uint32_t cfg = ss2_sa_make_config(SS2_SA_DTYPE_INT4,
                                    SS2_SA_DTYPE_INT4,
                                    1u, 1u, 1u, 1u);
  ss2_sa_write32(SS2_SA_OFF_CONFIG, cfg);
  ss2_print_check_u32("config readback", cfg, ss2_sa_read32(SS2_SA_OFF_CONFIG), &errors);

  ss2_sa_write32(SS2_SA_OFF_CONTROL, SS2_SA_CTRL_LOAD_WEIGHTS);
  if (ss2_sa_wait_phase(SS2_SA_PH_LOAD_WEIGHTS, 2000u, &status) != 0) {
    ss2_print_str("[FAIL] load weight phase timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check("load weight phase reached", 1);
  }

  const int32_t weight_col0[1] = {3};
  ss2_sa_stream_weight_vector(weight_col0, SS2_SA_DTYPE_INT4, 1u);

  if (ss2_sa_wait_phase(SS2_SA_PH_BATCH_COMPUTE, 4000u, &status) != 0) {
    ss2_print_str("[FAIL] compute phase timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check_u32("weights valid after load",
                        1u,
                        ss2_sa_status_weights_valid(status),
                        &errors);
  }

  const int32_t act_row0[1] = {4};
  ss2_sa_stream_activation_vector(act_row0, SS2_SA_DTYPE_INT4, 1u);

  if (ss2_sa_wait_output_valid(8000u, &status) != 0) {
    ss2_print_str("[FAIL] output valid timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check_u32("output word count",
                        2u,
                        ss2_sa_status_output_words(status),
                        &errors);
    int32_t got = (int32_t)ss2_sa_read_output_elem(0u, 0u, 1u);
    ss2_print_check_i32("1x1 output 4*3", 12, got, &errors);
  }

  ss2_sa_release_output();
  if (ss2_sa_wait_phase(SS2_SA_PH_IDLE, 4000u, &status) != 0) {
    ss2_print_str("[FAIL] idle after release timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check("idle after release", 1);
  }

  if (errors == 0) {
    ss2_print_str("SS2 SMOKE TEST PASS\r\n");
  } else {
    ss2_print_str("SS2 SMOKE TEST FAIL errors=");
    ss2_print_i32(errors);
    ss2_print_str("\r\n");
  }

  while (1) {
  }
}
