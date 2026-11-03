#include "USBBridge.h"
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stddef.h>

// Read-only AppleSMC user-client ABI. Only metadata (9) and read (5) are exposed.
// Layout and M4 sensor identifiers checked against the Stats primary implementation.
typedef struct {
    uint32_t key;
    uint8_t version_and_limits[24];
    uint32_t length;
    uint32_t type;
    uint8_t attributes;
    uint8_t alignment[1];
    uint16_t reserved;
    uint8_t result;
    uint8_t status;
    uint8_t action;
    uint8_t action_alignment[1];
    uint32_t index;
    uint8_t bytes[32];
} MCReadPacket;
_Static_assert(sizeof(MCReadPacket)==80,"AppleSMC packet size");
_Static_assert(offsetof(MCReadPacket,action)==42,"AppleSMC action offset");

int32_t mc_smc_read(const char *key,uint8_t *bytes,uint32_t *type,uint32_t *size){
    if(!key || strlen(key)!=4 || !bytes || !type || !size)return kIOReturnBadArgument;
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!service)return kIOReturnNotFound;
    io_connect_t connection=0;
    IOReturn error=IOServiceOpen(service,mach_task_self(),0,&connection);IOObjectRelease(service);
    if(error)return error;
    MCReadPacket request={0},response={0};
    for(int i=0;i<4;i++)request.key=(request.key<<8)|(uint8_t)key[i];
    request.action=9;size_t outputSize=sizeof(response);
    error=IOConnectCallStructMethod(connection,2,&request,sizeof(request),&response,&outputSize);
    if(!error && (outputSize!=sizeof(response) || response.result || response.length==0 || response.length>32))error=kIOReturnNotFound;
    if(!error){
        *type=response.type;*size=response.length;request.length=response.length;request.action=5;
        memset(&response,0,sizeof(response));outputSize=sizeof(response);
        error=IOConnectCallStructMethod(connection,2,&request,sizeof(request),&response,&outputSize);
        if(!error && (outputSize!=sizeof(response) || response.result))error=kIOReturnNotFound;
        if(!error)memcpy(bytes,response.bytes,*size);
    }
    IOServiceClose(connection);return error;
}
