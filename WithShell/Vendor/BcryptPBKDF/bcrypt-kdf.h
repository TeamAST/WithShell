#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <inttypes.h>

int
ws_bcrypt_pbkdf(const unsigned char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                     uint8_t *key, size_t keylen, unsigned int rounds);


