// keepalive: hold the TubeStick (1d2c:1012) open and read one bridge register every few seconds, so the stick never sits
// silent. After a gap with no host traffic the stick stops answering until it is replugged; holding it open with a
// periodic read prevents that. Read-only. Stop it (tools/keepalive.sh stop) before running capture or live viewing, because
// the device can only be opened by one program at a time.
// Build: clang -o build/keepalive tools/keepalive.c -framework IOKit -framework CoreFoundation
// Usage: keepalive [interval-seconds]   (default 5)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile sig_atomic_t stop;
static void onSig(int s) { stop = 1; }

static IOUSBDeviceInterface320 **openStick(void) {
    int vid = 0x1d2c, pid = 0x1012;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid), p = CFNumberCreate(0, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, m);
    if (!svc) return NULL;
    IOCFPlugInInterface **plug = NULL; SInt32 sc;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &sc);
    IOObjectRelease(svc);
    if (!plug) return NULL;
    IOUSBDeviceInterface320 **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return NULL;
    if ((*dev)->USBDeviceOpen(dev)) { (*dev)->Release(dev); return NULL; }
    return dev;
}

static int readId(IOUSBDeviceInterface320 **dev) {
    uint8_t b = 0;
    IOUSBDevRequest r = { .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice), .bRequest = 0, .wValue = 0, .wIndex = 0x0a, .wLength = 1, .pData = &b };
    return (*dev)->DeviceRequest(dev, &r) == kIOReturnSuccess ? b : -1;
}

int main(int argc, char **argv) {
    int interval = argc > 1 ? atoi(argv[1]) : 5; if (interval < 1) interval = 5;
    signal(SIGINT, onSig); signal(SIGTERM, onSig);
    IOUSBDeviceInterface320 **dev = NULL;
    while (!stop) {
        if (!dev) { dev = openStick(); if (dev) { printf("keepalive: stick opened\n"); fflush(stdout); } }
        if (dev && readId(dev) != 0x24) { printf("keepalive: stick not answering, closing and retrying\n"); fflush(stdout); (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); dev = NULL; }
        for (int i = 0; i < interval * 10 && !stop; i++) usleep(100000);
    }
    if (dev) { (*dev)->USBDeviceClose(dev); (*dev)->Release(dev); }
    return 0;
}
