// usbdesc: print the interfaces, alternate settings and endpoints of the TubeStick (1d2c:1012).
// Build: clang -o build/usbdesc tools/usbdesc.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

int main(void) {
    int vid = 0x1d2c, pid = 0x1012;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid), p = CFNumberCreate(0, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v); CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, m);
    if (!svc) { puts("not found"); return 1; }
    IOCFPlugInInterface **plug = NULL; SInt32 sc;
    IOReturn kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &sc);
    if (kr) printf("IOCreatePlugInInterfaceForService: 0x%x\n", kr);
    if (!plug) { puts("no plug-in"); return 1; }
    IOUSBDeviceInterface320 **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&dev);
    if (!dev) { puts("no device interface"); return 1; }
    UInt8 nconf; (*dev)->GetNumberOfConfigurations(dev, &nconf);
    printf("configurations: %d\n", nconf);
    IOUSBConfigurationDescriptorPtr cd = NULL;
    IOReturn r = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cd);
    if (r || !cd) { printf("GetConfigurationDescriptorPtr failed 0x%x\n", r); return 1; }
    UInt16 total = USBToHostWord(cd->wTotalLength);
    const UInt8 *b = (const UInt8 *)cd; printf("config total length %d, interfaces %d\n", total, cd->bNumInterfaces);
    for (int i = 0; i < total;) {
        int l = b[i], t = b[i + 1];
        if (t == 4) printf("  interface %d alt %d endpoints %d class %02x\n", b[i + 2], b[i + 3], b[i + 4], b[i + 5]);
        else if (t == 5) printf("    endpoint 0x%02x attrs 0x%02x maxpacket %d interval %d\n", b[i + 2], b[i + 3], b[i + 4] | (b[i + 5] << 8), b[i + 6]);
        i += l ? l : 1;
    }
    return 0;
}
