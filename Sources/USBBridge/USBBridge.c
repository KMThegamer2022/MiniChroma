#include "USBBridge.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/file.h>
#include <fcntl.h>
#include <stdio.h>
struct MCUSB { IOUSBDeviceInterface320 **device; int lock; };
MCUSB *mc_open(int32_t *error) {
    CFMutableDictionaryRef match=IOServiceMatching(kIOUSBDeviceClassName);
    int vid=0x1532,pid=0x008c;
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vid),p=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFDictionarySetValue(match,CFSTR(kUSBVendorID),v); CFDictionarySetValue(match,CFSTR(kUSBProductID),p); CFRelease(v);CFRelease(p);
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,match);
    if(!service){*error=kIOReturnNoDevice;return NULL;}
    IOCFPlugInInterface **plugin=NULL; SInt32 score=0;
    IOReturn result=IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
    IOObjectRelease(service);
    if(result || !plugin){*error=result;return NULL;}
    IOUSBDeviceInterface320 **dev=NULL;
    HRESULT hr=(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320),(LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    if(hr || !dev){*error=kIOReturnUnsupported;return NULL;}
    // DeviceRequest does not seize or detach the normal HID mouse interfaces.
    char path[128];snprintf(path,sizeof(path),"/tmp/minichroma-%u-1532-008c.lock",getuid());
    int lock=open(path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
    if(lock<0 || flock(lock,LOCK_EX|LOCK_NB)!=0){if(lock>=0)close(lock);(*dev)->Release(dev);*error=kIOReturnExclusiveAccess;return NULL;}
    MCUSB *handle=calloc(1,sizeof(MCUSB));handle->device=dev;handle->lock=lock;*error=0;return handle;
}
void mc_close(MCUSB *device){if(device){if(device->device)(*device->device)->Release(device->device);close(device->lock);free(device);}}
int32_t mc_exchange(MCUSB *device,const uint8_t *request,uint8_t *response){
    if(!device)return kIOReturnNoDevice;
    IOUSBDevRequestTO req={0};req.bmRequestType=0x21;req.bRequest=9;req.wValue=0x300;req.wIndex=0;req.wLength=90;req.pData=(void *)request;req.noDataTimeout=250;req.completionTimeout=250;
    // Query the timeout-capable interface without taking exclusive USB ownership.
    IOReturn result=(*device->device)->DeviceRequestTO(device->device,&req);if(result)return result;
    usleep(600);
    req.bmRequestType=0xa1;req.bRequest=1;req.pData=response;req.wLenDone=0;
    result=(*device->device)->DeviceRequestTO(device->device,&req);
    if(!result && req.wLenDone!=90)return kIOReturnUnderrun;
    return result;
}
