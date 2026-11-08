// regdump: read-only dump/watch of the Empia EM28xx bridge registers on an equinux TubeStick (USB 1d2c:1012).
// Built to run on OLD macOS (10.9+) next to the original TheTube app, to learn which registers change
// when the stick starts streaming. It only sends register READ requests.
//
//   regdump snapshot            print registers 0x00-0x7f once
//   regdump watch [seconds]     poll all registers and print every change with a timestamp (default 120 s)
//
// Build (see tools/build_regdump.sh):
//   clang -o regdump tools/regdump.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static IOUSBDeviceInterface320 **dev;

static int readReg(uint8_t reg, uint8_t *out) {
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice),
        .bRequest = 0x00, .wValue = 0, .wIndex = reg, .wLength = 1, .pData = out,
    };
    return (*dev)->DeviceRequest(dev, &r);
}

static double now(void) { struct timeval t; gettimeofday(&t, NULL); return t.tv_sec + t.tv_usec / 1e6; }

static int openStick(void) {
    int vid = 0x1d2c, pid = 0x1012;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid), p = CFNumberCreate(0, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, m);
    if (!svc) { fprintf(stderr, "TubeStick (1d2c:1012) not found. Is it plugged in?\n"); return 1; }
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (!plug) { fprintf(stderr, "could not create the USB plug-in interface\n"); return 1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { fprintf(stderr, "no device interface\n"); return 1; }
    IOReturn r = (*dev)->USBDeviceOpen(dev);
    if (r) {
        fprintf(stderr,
            "USBDeviceOpen failed (0x%x).\n"
            "If the original app has the stick open exclusively this can happen.\n"
            "Start regdump FIRST (snapshot or watch), then start the app, or see docs/old-machine-guide.md.\n", r);
        return 1;
    }
    return 0;
}

static void sweep(uint8_t *vals, uint8_t *ok) {
    for (int r = 0; r < 128; r++) ok[r] = readReg((uint8_t)r, &vals[r]) == kIOReturnSuccess;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "snapshot";
    if (openStick()) return 1;

    uint8_t cur[256] = {0}, prev[256] = {0}, ok[256] = {0};
    sweep(cur, ok);

    if (!strcmp(mode, "snapshot")) {
        printf("# TubeStick bridge registers (1d2c:1012), read-only snapshot\n");
        for (int base = 0; base < 128; base += 16) {
            printf("%02x:", base);
            for (int i = 0; i < 16; i++) { if (ok[base + i]) printf(" %02x", cur[base + i]); else printf(" --"); }
            printf("\n");
        }
        (*dev)->USBDeviceClose(dev);
        return 0;
    }

    int seconds = argc > 2 ? atoi(argv[2]) : 120;
    double t0 = now();
    printf("# watching for %d s; each line = elapsed seconds, register, old -> new\n", seconds);
    printf("# initial values:\n");
    for (int base = 0; base < 128; base += 16) {
        printf("#  %02x:", base);
        for (int i = 0; i < 16; i++) { if (ok[base + i]) printf(" %02x", cur[base + i]); else printf(" --"); }
        printf("\n");
    }
    fflush(stdout);
    memcpy(prev, cur, sizeof prev);
    while (now() - t0 < seconds) {
        sweep(cur, ok);
        for (int r = 0; r < 128; r++) {
            if (ok[r] && cur[r] != prev[r]) {
                printf("%7.2f  reg 0x%02x  %02x -> %02x\n", now() - t0, r, prev[r], cur[r]);
                prev[r] = cur[r];
            }
        }
        fflush(stdout);
        usleep(10000);
    }
    printf("# final values:\n");
    for (int base = 0; base < 128; base += 16) {
        printf("#  %02x:", base);
        for (int i = 0; i < 16; i++) { if (ok[base + i]) printf(" %02x", cur[base + i]); else printf(" --"); }
        printf("\n");
    }
    (*dev)->USBDeviceClose(dev);
    return 0;
}
