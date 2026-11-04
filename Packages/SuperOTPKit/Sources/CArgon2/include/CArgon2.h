#ifndef SUPEROTP_CARGON2_H
#define SUPEROTP_CARGON2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// BLAKE2b (unkeyed) with an output length of 1...64 bytes. Returns 0 on success.
int superotp_blake2b(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);

/// Argon2id, version 0x13 (RFC 9106). `secret` and `ad` may be NULL when their length is 0.
/// `m_cost_kib` is the memory size in KiB (one block per KiB). Returns 0 on success,
/// -1 for invalid parameters and -2 when the memory cannot be allocated.
int superotp_argon2id(
    const uint8_t *pwd, size_t pwdlen,
    const uint8_t *salt, size_t saltlen,
    const uint8_t *secret, size_t secretlen,
    const uint8_t *ad, size_t adlen,
    uint32_t t_cost, uint32_t m_cost_kib, uint32_t lanes,
    uint8_t *out, size_t outlen);

#ifdef __cplusplus
}
#endif

#endif
