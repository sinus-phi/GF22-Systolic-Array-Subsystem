#ifndef __GROUP2_SA_H__
#define __GROUP2_SA_H__

#include <stdint.h>
#include "soc_ctrl.h"

#define GROUP2_SA_SLOT 2u
#define GROUP2_SA_BASE 0x01520000u

#define GROUP2_SA_OFF_CONTROL      0x000u
#define GROUP2_SA_OFF_STATUS       0x004u
#define GROUP2_SA_OFF_CONFIG       0x008u
#define GROUP2_SA_OFF_PROGRESS     0x00Cu
#define GROUP2_SA_OFF_ERROR_CODE   0x010u
#define GROUP2_SA_OFF_OUTPUT_WORDS 0x014u
#define GROUP2_SA_OFF_VERSION      0x018u
#define GROUP2_SA_OFF_CAPABILITY   0x01Cu
#define GROUP2_SA_WEIGHT_DATA      0x100u
#define GROUP2_SA_ACT_DATA         0x200u
#define GROUP2_SA_BIAS_BASE        0x300u
#define GROUP2_SA_OUTPUT_BASE      0x400u

#define GROUP2_SA_CTRL_START_GEMM      (1u << 0)
#define GROUP2_SA_CTRL_START_GACC      (1u << 1)
#define GROUP2_SA_CTRL_CLEAR_DONE      (1u << 2)
#define GROUP2_SA_CTRL_CLEAR_ERROR     (1u << 3)
#define GROUP2_SA_CTRL_SOFT_RESET      (1u << 4)
#define GROUP2_SA_CTRL_RELEASE_CONTEXT (1u << 5)

#define GROUP2_SA_DTYPE_INT4  0u
#define GROUP2_SA_DTYPE_INT8  1u
#define GROUP2_SA_DTYPE_INT16 2u

#define GROUP2_SA_PH_IDLE       0u
#define GROUP2_SA_PH_WEIGHT     1u
#define GROUP2_SA_PH_ACTIVATION 2u
#define GROUP2_SA_PH_DRAIN      3u
#define GROUP2_SA_PH_GACC       4u
#define GROUP2_SA_PH_OUTPUT     5u
#define GROUP2_SA_PH_FATAL      6u

#define GROUP2_SA_ERR_NONE                 0u
#define GROUP2_SA_ERR_BAD_ADDR             1u
#define GROUP2_SA_ERR_UNALIGNED            2u
#define GROUP2_SA_ERR_PARTIAL_WRITE        3u
#define GROUP2_SA_ERR_BAD_STATE            4u
#define GROUP2_SA_ERR_INVALID_CONFIG       5u
#define GROUP2_SA_ERR_UNSUPPORTED_DTYPE    6u
#define GROUP2_SA_ERR_STREAM_COUNT         7u
#define GROUP2_SA_ERR_OUTPUT_NOT_READY     8u
#define GROUP2_SA_ERR_INVALID_GACC_CONTEXT 9u
#define GROUP2_SA_ERR_BIAS_NOT_READY       10u
#define GROUP2_SA_ERR_ILLEGAL_COMMAND      11u
#define GROUP2_SA_ERR_FATAL_INTERNAL       12u

#define GROUP2_SA_K_TILE       8u
#define GROUP2_SA_LOGICAL_N    32u
#define GROUP2_SA_MAX_M        32u
#define GROUP2_SA_OUTPUT_WORDS_PER_ROW 16u

static inline void group2_sa_write32(uint32_t offset, uint32_t value)
{
  *(volatile uint32_t *)(GROUP2_SA_BASE + offset) = value;
}

static inline uint32_t group2_sa_read32(uint32_t offset)
{
  return *(volatile uint32_t *)(GROUP2_SA_BASE + offset);
}

static inline void group2_sa_enable(void)
{
  ss_init(GROUP2_SA_SLOT);
}

static inline void group2_sa_disable(void)
{
  ss_reset(GROUP2_SA_SLOT);
}

static inline uint32_t group2_sa_make_config(uint32_t act_dtype,
                                             uint32_t weight_dtype,
                                             uint32_t rows_m,
                                             uint32_t bias_enable)
{
  return ((act_dtype & 0x3u) |
          ((weight_dtype & 0x3u) << 2) |
          ((rows_m & 0x3Fu) << 4) |
          ((bias_enable & 0x1u) << 10));
}

static inline uint32_t group2_sa_status_phase(uint32_t status)
{
  return (status >> 5) & 0x7u;
}

static inline uint32_t group2_sa_status_busy(uint32_t status)
{
  return status & 0x1u;
}

static inline uint32_t group2_sa_status_error(uint32_t status)
{
  return (status >> 1) & 0x1u;
}

static inline uint32_t group2_sa_status_done(uint32_t status)
{
  return (status >> 2) & 0x1u;
}

static inline uint32_t group2_sa_status_context_valid(uint32_t status)
{
  return (status >> 3) & 0x1u;
}

static inline uint32_t group2_sa_status_output_readable(uint32_t status)
{
  return (status >> 4) & 0x1u;
}

static inline uint32_t group2_sa_output_words(void)
{
  return group2_sa_read32(GROUP2_SA_OFF_OUTPUT_WORDS);
}

static inline void group2_sa_soft_reset(void)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_SOFT_RESET);
}

static inline void group2_sa_clear_error(void)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_CLEAR_ERROR);
}

static inline void group2_sa_release_context(void)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_RELEASE_CONTEXT);
}

static inline int group2_sa_wait_phase(uint32_t expected_phase,
                                       uint32_t timeout_reads,
                                       uint32_t *last_status)
{
  uint32_t status = 0u;
  while (timeout_reads-- > 0u) {
    status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
    if (group2_sa_status_error(status)) {
      if (last_status) *last_status = status;
      return -2;
    }
    if (group2_sa_status_phase(status) == expected_phase) {
      if (last_status) *last_status = status;
      return 0;
    }
  }
  if (last_status) *last_status = status;
  return -1;
}

static inline int group2_sa_wait_output(uint32_t timeout_reads,
                                        uint32_t *last_status)
{
  uint32_t status = 0u;
  while (timeout_reads-- > 0u) {
    status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
    if (group2_sa_status_error(status)) {
      if (last_status) *last_status = status;
      return -2;
    }
    if (group2_sa_status_output_readable(status)) {
      if (last_status) *last_status = status;
      return 0;
    }
  }
  if (last_status) *last_status = status;
  return -1;
}

static inline uint32_t group2_sa_dtype_width(uint32_t dtype)
{
  if (dtype == GROUP2_SA_DTYPE_INT4) return 4u;
  if (dtype == GROUP2_SA_DTYPE_INT8) return 8u;
  if (dtype == GROUP2_SA_DTYPE_INT16) return 16u;
  return 0u;
}

static inline uint32_t group2_sa_elems_per_word(uint32_t dtype)
{
  uint32_t width = group2_sa_dtype_width(dtype);
  return width ? (32u / width) : 0u;
}

static inline int group2_sa_value_fits(int32_t value, uint32_t dtype)
{
  if (dtype == GROUP2_SA_DTYPE_INT4) return value >= -8 && value <= 7;
  if (dtype == GROUP2_SA_DTYPE_INT8) return value >= -128 && value <= 127;
  if (dtype == GROUP2_SA_DTYPE_INT16) return value >= -32768 && value <= 32767;
  return 0;
}

static inline int group2_sa_validate_vector(const int32_t *values,
                                            uint32_t dtype,
                                            uint32_t valid_k)
{
  if (!values || valid_k > GROUP2_SA_K_TILE ||
      group2_sa_dtype_width(dtype) == 0u) return -1;
  for (uint32_t k = 0u; k < valid_k; ++k) {
    if (!group2_sa_value_fits(values[k], dtype)) return -1;
  }
  return 0;
}

static inline uint32_t group2_sa_pack_vector_word(const int32_t *values,
                                                  uint32_t dtype,
                                                  uint32_t valid_k,
                                                  uint32_t word_index)
{
  uint32_t width = group2_sa_dtype_width(dtype);
  uint32_t elems = group2_sa_elems_per_word(dtype);
  uint32_t mask = (width == 16u) ? 0xFFFFu : ((1u << width) - 1u);
  uint32_t word = 0u;
  for (uint32_t lane = 0u; lane < elems; ++lane) {
    uint32_t k = word_index * elems + lane;
    uint32_t bits = (k < valid_k) ? ((uint32_t)values[k] & mask) : 0u;
    word |= bits << (lane * width);
  }
  return word;
}

static inline int group2_sa_stream_vector(uint32_t port_offset,
                                          const int32_t *values,
                                          uint32_t dtype,
                                          uint32_t valid_k)
{
  uint32_t elems = group2_sa_elems_per_word(dtype);
  if (group2_sa_validate_vector(values, dtype, valid_k) != 0 || elems == 0u) {
    return -1;
  }
  for (uint32_t word = 0u; word < GROUP2_SA_K_TILE / elems; ++word) {
    group2_sa_write32(port_offset,
                      group2_sa_pack_vector_word(values, dtype, valid_k, word));
  }
  return 0;
}

static inline int group2_sa_stream_packed_words(uint32_t port_offset,
                                                const uint32_t *packed_words,
                                                uint32_t word_count)
{
  if (!packed_words || word_count == 0u) return -1;
  for (uint32_t word = 0u; word < word_count; ++word) {
    group2_sa_write32(port_offset, packed_words[word]);
  }
  return 0;
}

static inline int group2_sa_stream_weight_packed(const uint32_t *packed_words,
                                                 uint32_t word_count)
{
  return group2_sa_stream_packed_words(GROUP2_SA_WEIGHT_DATA,
                                       packed_words, word_count);
}

static inline int group2_sa_stream_activation_packed(const uint32_t *packed_words,
                                                     uint32_t word_count)
{
  return group2_sa_stream_packed_words(GROUP2_SA_ACT_DATA,
                                       packed_words, word_count);
}

static inline int group2_sa_stream_weight_vector(const int32_t *values,
                                                 uint32_t dtype,
                                                 uint32_t valid_k)
{
  return group2_sa_stream_vector(GROUP2_SA_WEIGHT_DATA, values, dtype, valid_k);
}

static inline int group2_sa_stream_activation_vector(const int32_t *values,
                                                     uint32_t dtype,
                                                     uint32_t valid_k)
{
  return group2_sa_stream_vector(GROUP2_SA_ACT_DATA, values, dtype, valid_k);
}

static inline void group2_sa_write_bias_pair(uint32_t pair,
                                             int16_t low,
                                             int16_t high)
{
  uint32_t word = (uint16_t)low | ((uint32_t)(uint16_t)high << 16);
  group2_sa_write32(GROUP2_SA_BIAS_BASE + pair * 4u, word);
}

static inline uint32_t group2_sa_read_output_word(uint32_t row,
                                                  uint32_t word_index)
{
  uint32_t offset = GROUP2_SA_OUTPUT_BASE + row * 64u + word_index * 4u;
  return group2_sa_read32(offset);
}

static inline void group2_sa_read_output_words(uint32_t rows,
                                               uint32_t words_per_row,
                                               uint32_t *output_words)
{
  for (uint32_t row = 0u; row < rows; ++row) {
    for (uint32_t word = 0u; word < words_per_row; ++word) {
      output_words[row * words_per_row + word] =
          group2_sa_read_output_word(row, word);
    }
  }
}

static inline int16_t group2_sa_output_word_low(uint32_t word)
{
  return (int16_t)word;
}

static inline int16_t group2_sa_output_word_high(uint32_t word)
{
  return (int16_t)(word >> 16);
}

static inline int16_t group2_sa_read_output_elem(uint32_t row, uint32_t col)
{
  uint32_t word = group2_sa_read_output_word(row, col >> 1);
  return (col & 1u) ? group2_sa_output_word_high(word)
                    : group2_sa_output_word_low(word);
}

static inline uint16_t group2_sa_add_wrap16(uint16_t lhs, uint16_t rhs)
{
  return (uint16_t)(lhs + rhs);
}

static inline uint16_t group2_sa_mul_wrap16(int16_t lhs, int16_t rhs)
{
  return (uint16_t)((int32_t)lhs * (int32_t)rhs);
}

#endif
