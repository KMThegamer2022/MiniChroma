#include <stdint.h>
typedef struct MCUSB MCUSB;
MCUSB *mc_open(int32_t *error);
void mc_close(MCUSB *device);
int32_t mc_exchange(MCUSB *device, const uint8_t *request, uint8_t *response);
int32_t mc_smc_read(const char *key, uint8_t *bytes, uint32_t *type, uint32_t *size);
