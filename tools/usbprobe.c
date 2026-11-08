// usbprobe: list USB devices via IOKit and flag equinux TubeStick-family IDs.
// Build: clang -o build/usbprobe tools/usbprobe.c -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

static int num(io_service_t s, CFStringRef key) {
    int v = -1;
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (r) { CFNumberGetValue(r, kCFNumberIntType, &v); CFRelease(r); }
    return v;
}

int main(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)) return 1;
    int found = 0;
    for (io_service_t s; (s = IOIteratorNext(it)); IOObjectRelease(s)) {
        int vid = num(s, CFSTR("idVendor")), pid = num(s, CFSTR("idProduct"));
        if (vid != 0x1d2c && vid != 0x15a4 && vid != 0xeb1a) continue;  // equinux, Afatech, Empia
        char name[128] = "?";
        CFTypeRef n = IORegistryEntryCreateCFProperty(s, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
        if (n) { CFStringGetCString(n, name, sizeof name, kCFStringEncodingUTF8); CFRelease(n); }
        printf("%04x:%04x  %s\n", vid, pid, name);
        found++;
    }
    if (!found) puts("no equinux/Afatech/Empia devices found");
    IOObjectRelease(it);
    return 0;
}
