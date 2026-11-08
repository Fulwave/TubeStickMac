// em28xxprobe: READ-ONLY probe of an equinux TubeStick Hybrid (Empia EM2883, USB 1d2c:1012).
// Reads bridge registers, the I2C EEPROM, and scans the I2C bus for chips.
// Read-only by default. Writes only happen with explicit flags:
//   --i2c   write bridge reg 0x06 (I2C clock) = 0x41 (100 kHz, wait enable), then scan.
//   --gpio  clear GPIO reg 0x08 bits 7,6,5,3 in that order (what the old driver does for chip id 0x24,
//           from EQTVKit configureGPIO), 50 ms apart. Add --gpio-high to set them instead.
//   XCFW=<file> (env, with --i2c) load the XC5000 firmware sequence into the tuner, then read its product id.
//   (I2C EEPROM access also sends a 1-byte offset write to the EEPROM.)
//
// Build: clang -o build/em28xxprobe tools/em28xxprobe.c -framework IOKit -framework CoreFoundation
// Run:   ./build/em28xxprobe [--i2c]        (device fixed at 1d2c:1012 unless "vid pid" given last)
//
// Protocol (from the Linux em28xx driver's public behavior):
//   register read:  IN  vendor request 0x00, wIndex = register, wValue = 0
//   I2C read:       IN  vendor request 0x02, wIndex = 8-bit address form (7-bit << 1), wValue = 0, wLength = n
//   I2C write:      OUT vendor request 0x02 (with stop), wIndex = 8-bit address form
//   I2C status:     register 0x05 (0x00 = ok, 0x10 = busy, bit 0x04 = error/no ack)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static IOUSBDeviceInterface320 **dev;
static int addrShift;  // 1 (default): wIndex = 8-bit form (7-bit addr << 1), what the bridge expects. ADDR7=1 for raw 7-bit.

static IOReturn ctl(uint8_t dir, uint8_t req, uint16_t value, uint16_t index, void *buf, uint16_t len) {
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(dir, kUSBVendor, kUSBDevice),
        .bRequest = req, .wValue = value, .wIndex = index, .wLength = len, .pData = buf,
    };
    return (*dev)->DeviceRequest(dev, &r);
}

static int writeReg(uint8_t reg, uint8_t val) { return ctl(kUSBOut, 0x00, 0, reg, &val, 1); }

static int readReg(uint8_t reg, uint8_t *out) { return ctl(kUSBIn, 0x00, 0, reg, out, 1); }

static int i2cStatus(void) { uint8_t s = 0xff; return readReg(0x05, &s) ? -1 : s; }

// Returns 0 on ACK + data read.
static int i2cRead(uint8_t addr7, uint8_t *buf, uint16_t n) {
    return ctl(kUSBIn, 0x02, 0, addr7 << addrShift, buf, n);
}

static int i2cWrite(uint8_t addr7, uint8_t *buf, uint16_t n) {
    return ctl(kUSBOut, 0x02, 0, addr7 << addrShift, buf, n);
}

static const char *guess(uint8_t a) {
    switch (a) {
        case 0x0e: return "LGDT3304 demodulator (8-bit 0x1c)";
        case 0x44: return "CX2584x analog decoder (8-bit 0x88)";
        case 0x41: return "AVF49B analog decoder? (8-bit 0x82)";
        case 0x35: return "XC5000 tuner? (8-bit 0x6a)";
        case 0x61: return "XC5000 tuner (Linux default, 8-bit 0xc2)";
        case 0x60: return "tuner (TDA18271/XC3028 family, 8-bit 0xc0)";
        case 0x50: return "EEPROM 24Cxx (8-bit 0xa0)";
        case 0x4b: return "DRX demodulator? (8-bit 0x96)";
        case 0x2d: return "MT353 demodulator? (8-bit 0x5a)";
        default: return "";
    }
}


// ---- ATSC tuning (values from the old EQTVKit driver; see docs/findings.md) ----
static int xcWrite(uint8_t reg, uint16_t v) { uint8_t b[4] = {0, reg, (uint8_t)(v >> 8), (uint8_t)v}; return i2cWrite(0x61, b, 4); }
static int xcRead(uint8_t reg, uint16_t *v) {
    uint8_t rq[2] = {0, reg}, d[2] = {0, 0};
    int e = i2cWrite(0x61, rq, 2); if (!e) e = i2cRead(0x61, d, 2);
    *v = (d[0] << 8) | d[1]; return e;
}
// Like the Linux xc5000 driver: if the tuner already reports product id 0x1388 its firmware is running, so do not load it again.
// Reloading into a running tuner has hung the stick's I2C engine (loads stop after 4 writes, then every request fails until replug).
// FORCE_FW=1 overrides.
static int xcAlreadyLoaded(void) {
    uint16_t id = 0;
    if (getenv("FORCE_FW")) return 0;
    if (xcRead(0x08, &id) == 0 && id == 0x1388) { printf("XC5000 firmware already loaded (product id 0x1388): skipping the load\n"); return 1; }
    return 0;
}
static int lgWrite(uint16_t reg, uint8_t v) { uint8_t b[3] = {(uint8_t)(reg >> 8), (uint8_t)reg, v}; return i2cWrite(0x0e, b, 3); }
static uint8_t lgRead(uint16_t reg) { uint8_t rq[2] = {(uint8_t)(reg >> 8), (uint8_t)reg}, d = 0; i2cWrite(0x0e, rq, 2); i2cRead(0x0e, &d, 1); return d; }
static void lgRmw(uint16_t reg, uint8_t andMask, uint8_t orMask) { lgWrite(reg, (lgRead(reg) & andMask) | orMask); }

// LGDT3304 reset + 8VSB init, transcribed from the old driver's _reset and _initVSB.
static void lgInitVSB(void) {
    lgRmw(0x0002, 0xfe, 0x00); usleep(1000);
    lgRmw(0x0002, 0xff, 0x01); usleep(1000);
    lgRmw(0x0000, 0xff, 0x03);
    lgWrite(0x000d, 0x02); lgWrite(0x000e, 0x02); lgWrite(0x0012, 0x32); lgWrite(0x0013, 0xc4);
    lgWrite(0x0112, 0x17); lgWrite(0x0113, 0x15); lgWrite(0x0114, 0x18); lgWrite(0x0115, 0xff);
    lgRmw(0x0116, 0xf8, 0x04); lgRmw(0x0214, 0xf0, 0x07);
    lgWrite(0x0424, 0x8d); lgWrite(0x0427, 0x12); lgWrite(0x0428, 0x4f);
    lgWrite(0x0308, 0x80); lgWrite(0x0309, 0x00);
    lgRmw(0x030d, 0xff, 0x10); lgRmw(0x030d, 0xff, 0x04);
    lgRmw(0x030e, 0xbf, 0x00); lgRmw(0x030e, 0xfe, 0x00);
    lgWrite(0x0314, 0xe1); lgWrite(0x050e, 0x5b);
}

// Tune the XC5000 to an ATSC (6 MHz) channel centered at centerMHz. IF 6.0 MHz, RF = center - 1.75 MHz.
static void xcTuneATSC(double centerMHz) {
    xcWrite(0x0d, getenv("RFSRC") ? (uint16_t)atoi(getenv("RFSRC")) : 0);  // signal source: 0 air, 1 cable (Linux); old code writes the opposite polarity
    xcWrite(0x01, 0x8002);          // video mode DTV6
    xcWrite(0x02, 0x00c0);          // audio mode DTV6
    xcWrite(0x05, (uint16_t)(6.0 * 1024));
    xcWrite(0x03, (uint16_t)((centerMHz - 1.75) / 0.015625));
}

static int channelCenter(int ch) {
    if (ch >= 2 && ch <= 4) return 57 + 6 * (ch - 2);
    if (ch == 5) return 79;
    if (ch == 6) return 85;
    if (ch >= 7 && ch <= 13) return 177 + 6 * (ch - 7);
    if (ch >= 14 && ch <= 51) return 473 + 6 * (ch - 14);
    return 0;
}

static void scanATSC(void) {
    uint16_t id = 0; xcRead(0x08, &id);
    if (id != 0x1388) { printf("XC5000 firmware not loaded (id 0x%04x); run with XCFW first\n", id); return; }
    xcWrite(0x00, 0x0000);  // xc_initialize, as the old driver does after the firmware load
    usleep(100000);
    lgInitVSB();
    printf("\nATSC scan (prints channels where the demodulator reports lock; ALL=1 prints every channel):\n");
    int only[64], nOnly = 0;
    if (getenv("CHS")) { char *t = strdup(getenv("CHS")); for (char *q = strtok(t, ","); q && nOnly < 64; q = strtok(NULL, ",")) only[nOnly++] = atoi(q); }
    for (int ch = 2; ch <= 51; ch++) {
        if (nOnly) { int ok = 0; for (int k = 0; k < nOnly; k++) ok |= only[k] == ch; if (!ok) continue; }
        int c = channelCenter(ch); if (!c) continue;
        xcTuneATSC(c);
        for (int w = 0; w < 40; w++) { uint16_t busy = 1; xcRead(0x09, &busy); if (!busy) break; usleep(20000); }
        usleep(500000);
        uint16_t adc = 0, snr = 0; xcRead(0x00, &adc); xcRead(0x06, &snr);
        // Old driver's VSB lock test: locked when bit 1 of reg 0x0409 is clear; regs 0x0417-0x0419 are a 24-bit error counter.
        int locks = 0, samples = 5; unsigned lastCount = 0;
        for (int k = 0; k < samples; k++) {
            if (k) usleep(300000);
            uint8_t r9 = lgRead(0x0409), a = lgRead(0x0417), b = lgRead(0x0418), d = lgRead(0x0419);
            locks += !(r9 & 2); lastCount = (a << 16) | (b << 8) | d;
        }
        xcRead(0x00, &adc);
        if (locks || getenv("ALL")) printf("  ch %2d  %3d MHz  tuner level %4u  demod locked %d/%d  last error count %u\n", ch, c, adc, locks, samples, lastCount);
    }
}

// ---- Transport stream capture over the isochronous endpoint ----
#include <IOKit/usb/IOUSBLib.h>
#include <time.h>
#define NFR 32
#define NBUF 6
typedef struct { IOUSBIsocFrame fr[NFR]; uint8_t *buf; int idx; } XferCtx;
static IOUSBInterfaceInterface300 **intf;
static UInt8 capPipe; static UInt32 capFrameBytes; static UInt64 capNextFrame; static FILE *capOut;
static unsigned long capHist[6], capZeroRuns, capCurZero, capMaxZeroRun; static unsigned long capBytes, capSync, capErrors, capCallbacks, capBadFrames; static IOReturn capLastResult, capLastFrameStatus; static int capStop;
static XferCtx ctxs[NBUF];

static void isoDone(void *refcon, IOReturn result, void *arg0);
static void submit(XferCtx *c) {
    for (int i = 0; i < NFR; i++) { c->fr[i].frReqCount = (UInt16)capFrameBytes; c->fr[i].frActCount = 0; c->fr[i].frStatus = 0; }
    UInt64 now; AbsoluteTime at; (*intf)->GetBusFrameNumber(intf, &now, &at);
    if (capNextFrame < now + 8) capNextFrame = now + 8;   // never schedule in the past
    IOReturn e = (*intf)->ReadIsochPipeAsync(intf, capPipe, c->buf, capNextFrame, NFR, c->fr, isoDone, c);
    if (e) { capErrors++; if (capErrors < 4) printf("  ReadIsochPipeAsync error 0x%x (frame %llu, now %llu)\n", e, capNextFrame, now); }
    capNextFrame += NFR;
}
static void isoDone(void *refcon, IOReturn result, void *arg0) {
    XferCtx *c = refcon; (void)arg0; capCallbacks++; capLastResult = result;
    if (result != kIOReturnSuccess && result != kIOReturnUnderrun) { capErrors++; }
    for (int i = 0; i < NFR; i++) {
        UInt32 n = c->fr[i].frActCount;
        { int b = n == 0 ? 0 : n < 188 ? 1 : n < 752 ? 2 : n == 752 ? 3 : n < 1504 ? 4 : 5; capHist[b]++; if (n == 0) { capCurZero++; if (capCurZero > capMaxZeroRun) capMaxZeroRun = capCurZero; } else { if (capCurZero) capZeroRuns++; capCurZero = 0; } }
        if (c->fr[i].frStatus) { capBadFrames++; capLastFrameStatus = c->fr[i].frStatus; }
        if (n && n <= capFrameBytes) {
            const uint8_t *d = c->buf + (size_t)i * capFrameBytes;
            fwrite(d, 1, n, capOut); capBytes += n;
            for (UInt32 k = 0; k + 188 <= n; k += 188) if (d[k] == 0x47) capSync++;
        }
    }
    if (!capStop) submit(c);  // keep NBUF transfers in flight
}


// Linux em28xx_capture_start() for old Empia chips, digital mode: R0C |= 0x10, R48 = 0, R12 = 0x37, wait 10 ms.
static void captureStartRegs(void) {
    uint8_t r0c = 0; readReg(0x0c, &r0c); writeReg(0x0c, r0c | 0x10); writeReg(0x48, 0x00); writeReg(0x12, 0x37); usleep(10000);
    uint8_t a = 0, b = 0, c = 0; readReg(0x0c, &a); readReg(0x48, &b); readReg(0x12, &c);
    printf("capture start regs: 0x0c=%02x 0x48=%02x 0x12=%02x\n", a, b, c);
}
// Linux em28xx_capture_start(0) for old Empia chips: R0C &= ~0x10, R12 = 0x27. Leaving the stream running with nobody
// reading it overflows the bridge FIFO and the stick stops answering after a while, so every capture must end with this.
static void captureStopRegs(void) {
    uint8_t r0c = 0; readReg(0x0c, &r0c); writeReg(0x0c, r0c & ~0x10); writeReg(0x12, 0x27);
    printf("capture stopped (stream disabled: reg 0x12 = 0x27)\n");
}
#ifdef USE_USBHOST
extern int tshost_capture(int vid, int pid, int alt, int ep, int seconds, const char *path, void (*afterAlt)(void));
#endif

static int captureTS(int ch, int seconds, int alt, int ep, const char *path) {
    int c = channelCenter(ch); if (!c) { printf("bad channel\n"); return 1; }
    uint16_t id = 0; xcRead(0x08, &id);
    if (id != 0x1388) { printf("XC5000 firmware not loaded (id 0x%04x); run with XCFW first\n", id); return 1; }
    xcWrite(0x00, 0); usleep(100000);
    lgInitVSB(); xcTuneATSC(c);
    for (int w = 0; w < 40; w++) { uint16_t busy = 1; xcRead(0x09, &busy); if (!busy) break; usleep(20000); }
    usleep(800000);
    int lock = !(lgRead(0x0409) & 2);
    printf("channel %d (%d MHz): demod %s\n", ch, c, lock ? "LOCKED" : "not locked");

    // Bridge: digital stream setup from the old driver's _startDigitalStream (chip id 0x24 path).
    writeReg(0x1c, 0x00); writeReg(0x1d, 0x20); writeReg(0x1e, 0x20); writeReg(0x1f, 0x20);
    { uint8_t r1b = 0; readReg(0x1b, &r1b); writeReg(0x1b, r1b & ~0x01); readReg(0x1b, &r1b); writeReg(0x1b, r1b & ~0x02); }  // old driver clears bits 0 and 1 of reg 0x1b
    if (getenv("WRITES")) { char *t = strdup(getenv("WRITES")); for (char *q = strtok(t, ","); q; q = strtok(NULL, ",")) { unsigned r, v; if (sscanf(q, "%x=%x", &r, &v) == 2) { writeReg((uint8_t)r, (uint8_t)v); printf("  extra write reg 0x%02x = 0x%02x\n", r, v); } } }
    writeReg(0x12, 0x37);
    { uint8_t r12 = 0, r1b = 0, r10 = 0, r11 = 0, r0f = 0; readReg(0x12, &r12); readReg(0x1b, &r1b); readReg(0x10, &r10); readReg(0x11, &r11); readReg(0x0f, &r0f); printf("bridge regs now: 0x0f=%02x 0x10=%02x 0x11=%02x 0x12=%02x 0x1b=%02x\n", r0f, r10, r11, r12, r1b); }

#ifdef USE_USBHOST
    if (getenv("USBHOST")) { (*dev)->SetConfiguration(dev, 1); return tshost_capture(0x1d2c, 0x1012, alt, ep, seconds, path, captureStartRegs); }
#endif
    (*dev)->SetConfiguration(dev, 1);
    IOUSBFindInterfaceRequest rq = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it; if ((*dev)->CreateInterfaceIterator(dev, &rq, &it)) { printf("no interface iterator\n"); return 1; }
    io_service_t isvc = IOIteratorNext(it);
    IOCFPlugInInterface **plug = NULL; SInt32 sc;
    if (!isvc || IOCreatePlugInInterfaceForService(isvc, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &sc) || !plug) { printf("no interface plug-in\n"); return 1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&intf);
    if (!intf) { printf("no interface\n"); return 1; }
    IOReturn r = (*intf)->USBInterfaceOpen(intf);
    if (r) { printf("USBInterfaceOpen 0x%x\n", r); return 1; }
    r = (*intf)->SetAlternateInterface(intf, alt);
    printf("SetAlternateInterface(%d) -> 0x%x\n", alt, r);
    captureStartRegs();
    UInt8 np = 0; (*intf)->GetNumEndpoints(intf, &np);
    capPipe = 0;
    for (UInt8 p = 1; p <= np; p++) {
        UInt8 dir, num, type, intv; UInt16 mp;
        (*intf)->GetPipeProperties(intf, p, &dir, &num, &type, &mp, &intv);
        printf("  pipe %d: endpoint 0x%02x type %d maxpacket %d\n", p, (dir ? 0x80 : 0) | num, type, mp);
        if (num == (ep & 0x7f) && dir) { capPipe = p; capFrameBytes = (UInt32)mp * (getenv("FMUL") ? atoi(getenv("FMUL")) : 4);  /* IOKit reports bytes per microframe incl. high-bandwidth multiplier; a frame is 8 microframes */ }
    }
    if (!capPipe) { printf("endpoint 0x%02x not present in alt %d\n", ep, alt); return 1; }
    printf("capturing from pipe %d, %u bytes per ms frame\n", capPipe, capFrameBytes);

    CFRunLoopSourceRef src; (*intf)->CreateInterfaceAsyncEventSource(intf, &src);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    capOut = fopen(path, "wb");
    UInt64 now; AbsoluteTime at; (*intf)->GetBusFrameNumber(intf, &now, &at);
    capNextFrame = now + 20;
    for (int i = 0; i < NBUF; i++) {
        ctxs[i].buf = malloc((size_t)capFrameBytes * NFR); ctxs[i].idx = i;
        submit(&ctxs[i]);
    }
    if (capErrors) { printf("initial ReadIsochPipeAsync failed (%lu)\n", capErrors); return 1; }
    time_t t0 = time(NULL);
    while (time(NULL) - t0 < seconds) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    capStop = 1;
    fclose(capOut);
    printf("callbacks %lu, last result 0x%x, bad frames %lu (last status 0x%x)\n", capCallbacks, capLastResult, capBadFrames, capLastFrameStatus);
    printf("frame size histogram (1 ms frames): 0 B: %lu | 1-187 B: %lu | 188-751 B: %lu | exactly 752 B: %lu | 753-1503 B: %lu | 1504+ B: %lu; zero-size runs %lu, longest %lu frames\n", capHist[0], capHist[1], capHist[2], capHist[3], capHist[4], capHist[5], capZeroRuns, capMaxZeroRun);
    printf("captured %lu bytes, %lu aligned 0x47 sync bytes, %lu errors -> %s\n", capBytes, capSync, capErrors, path);
    return 0;
}

int main(int argc, char **argv) {
    int vid = 0x1d2c, pid = 0x1012, doI2c = 0, doGpio = 0, gpioVal = 0, dumpAddr = -1, doScan = 0, capCh = 0, doReset = 0;
    for (int k = 1; k < argc; k++) if (!strcmp(argv[k], "--gpio") || !strcmp(argv[k], "--gpio-high")) { doGpio = 1; gpioVal = argv[k][6] == '-'; memmove(&argv[k], &argv[k + 1], (argc - k) * sizeof *argv); argc--; k--; }
    for (int k = 1; k + 1 < argc; k++) if (!strcmp(argv[k], "--dump")) { dumpAddr = (int)strtol(argv[k + 1], 0, 16); memmove(&argv[k], &argv[k + 2], (argc - k - 1) * sizeof *argv); argc -= 2; k--; }
    for (int k = 1; k + 1 < argc; k++) if (!strcmp(argv[k], "--capture")) { capCh = atoi(argv[k + 1]); memmove(&argv[k], &argv[k + 2], (argc - k - 1) * sizeof *argv); argc -= 2; k--; }
    for (int k = 1; k < argc; k++) if (!strcmp(argv[k], "--reset")) { doReset = 1; memmove(&argv[k], &argv[k + 1], (argc - k) * sizeof *argv); argc--; k--; }
    for (int k = 1; k < argc; k++) if (!strcmp(argv[k], "--scan")) { doScan = 1; memmove(&argv[k], &argv[k + 1], (argc - k) * sizeof *argv); argc--; k--; }
    for (int k = 1; k < argc; k++) if (!strcmp(argv[k], "--i2c")) { doI2c = 1; memmove(&argv[k], &argv[k + 1], (argc - k) * sizeof *argv); argc--; k--; }
    if (argc == 3) { vid = (int)strtol(argv[1], 0, 16); pid = (int)strtol(argv[2], 0, 16); }

    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid), p = CFNumberCreate(0, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, m);
    if (!svc) { fprintf(stderr, "device %04x:%04x not found\n", vid, pid); return 1; }

    IOCFPlugInInterface **plug = NULL; SInt32 score;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (!plug) { fprintf(stderr, "could not create plug-in interface\n"); return 1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) { fprintf(stderr, "no device interface\n"); return 1; }

    addrShift = getenv("ADDR7") ? 0 : 1;
    IOReturn r = (*dev)->USBDeviceOpen(dev);
    if (r) { fprintf(stderr, "USBDeviceOpen failed: 0x%x (another process may own it)\n", r); return 1; }
    printf("Opened %04x:%04x\n\n", vid, pid);
    if (doReset) {  // software "unplug and replug": re-enumerate the device on the bus
        IOReturn e = (*dev)->USBDeviceReEnumerate(dev, 0);
        printf("USBDeviceReEnumerate -> 0x%x; wait a few seconds before the next command\n", e);
        return 0;
    }

    printf("Bridge registers 0x00-0x1f (read-only):\n");
    for (int base = 0; base < 0x20; base += 16) {
        printf("  %02x:", base);
        for (int i = 0; i < 16; i++) {
            uint8_t b; int e = readReg(base + i, &b);
            if (e) printf(" ??"); else printf(" %02x", b);
        }
        printf("\n");
    }
    uint8_t id = 0; readReg(0x0a, &id);
    printf("  chip id (reg 0x0a) = 0x%02x\n", id);
    printf("  i2c status (reg 0x05) = 0x%02x\n", i2cStatus());

    if (doI2c) {
        uint8_t before = 0, after = 0; readReg(0x06, &before);
        IOReturn e = writeReg(0x06, 0x41); readReg(0x06, &after);
        printf("\nWrote reg 0x06 (I2C clock): 0x%02x -> 0x41, read back 0x%02x (ioreturn 0x%x), i2c status now 0x%02x\n", before, after, e, i2cStatus());
    }

    if (doGpio) {
        static const int bits[] = {7, 6, 5, 3};
        uint8_t g = 0; readReg(0x08, &g);
        printf("\nGPIO reg 0x08 before: 0x%02x\n", g);
        for (int k = 0; k < 4; k++) {
            g = gpioVal ? (g | (1 << bits[k])) : (g & ~(1 << bits[k]));
            writeReg(0x08, g); usleep(50000);
        }
        uint8_t back = 0; readReg(0x08, &back);
        printf("GPIO reg 0x08 wrote 0x%02x, read back 0x%02x\n", g, back);
        usleep(100000);
    }

    if (getenv("PREWRITES")) {  // PREWRITES="reg=val,reg=val": bridge writes applied now, 20 ms apart (e.g. GPIO state before the tuner firmware load)
        char *t = strdup(getenv("PREWRITES"));
        for (char *q = strtok(t, ","); q; q = strtok(NULL, ",")) { unsigned r, v; if (sscanf(q, "%x=%x", &r, &v) == 2) { writeReg((uint8_t)r, (uint8_t)v); usleep(20000); printf("prewrite reg 0x%02x = 0x%02x\n", r, v); } }
    }
    int noScan = getenv("NOSCAN") != NULL;  // NOSCAN=1: skip the blind scan (it may upset the tuner on some hosts)
    if (!noScan) {
    printf("\nI2C scan (7-bit addresses that ACK a 1-byte read):\n");
    int hits = 0;
    for (int a = 0x03; a < 0x78; a++) {
        uint8_t b = 0;
        if (i2cRead(a, &b, 1) == kIOReturnSuccess) {
            int st = i2cStatus();
            if (st == 0) { printf("  0x%02x (8-bit 0x%02x)  %s\n", a, a << 1, guess(a)); hits++; }
        }
    }
    if (!hits) printf("  none responded (the I2C clock or tuner power may need bridge setup)\n");
    if (getenv("VERBOSE")) {
        static const uint8_t t[] = {0x50, 0x0e, 0x44, 0x35, 0x61, 0x60};
        for (unsigned k = 0; k < sizeof t; k++) {
            uint8_t b = 0; IOReturn e = i2cRead(t[k], &b, 1);
            printf("  [verbose] addr 0x%02x: ioreturn=0x%x byte=%02x status=0x%02x\n", t[k], e, b, i2cStatus());
        }
    }
    }  // !noScan

    if (getenv("XCFW") && xcAlreadyLoaded()) setenv("XCID", "1", 1);
    else if (getenv("XCFW")) {
        // Load the XC5000 firmware sequence (the format of linux-firmware's dvb-fe-xc5000-1.6.114.fw).
        FILE *f = fopen(getenv("XCFW"), "rb");
        if (!f) { perror("XCFW"); return 1; }
        static uint8_t fw[0x4000]; size_t n = fread(fw, 1, sizeof fw, f); fclose(f);
        size_t i = 0; int writes = 0, bad = 0;
        while (i + 2 <= n) {
            unsigned len = (fw[i] << 8) | fw[i + 1]; i += 2;
            if (len == 0xFFFF) break;
            if (len == 0) { printf("  (sequence reset action skipped: tuner is already out of reset)\n"); continue; }
            if (len & 0x8000) { usleep((len & 0x7fff) * 1000); continue; }
            if (i + len > n) { printf("  truncated sequence\n"); bad++; break; }
            // Each write: 2-byte register header, then up to 62 data bytes, header repeated per chunk.
            const uint8_t *hdr = &fw[i], *data = &fw[i + 2]; unsigned remain = len - 2;
            do {
                unsigned c = remain > 62 ? 62 : remain;
                uint8_t buf[64]; buf[0] = hdr[0]; buf[1] = hdr[1]; memcpy(buf + 2, data, c);
                IOReturn e = i2cWrite(0x61, buf, 2 + c); int st = i2cStatus();
                if (e || st) { printf("  write failed: ioreturn=0x%x status=0x%02x at seq offset %zu\n", e, st, i); bad++; }
                data += c; remain -= c; writes++;
            } while (remain && !bad);
            i += len;
            if (bad) break;
        }
        printf("\nXC5000 firmware load: %d I2C writes, %d errors\n", writes, bad);
        usleep(100000);
        setenv("XCID", "1", 1);
    }

    if (getenv("XCID")) {
        // XC5000 product ID: write register 0x0008, read 2 bytes (expect 0x1388 = 5000).
        uint8_t rq[2] = {0x00, 0x08}, id2[2] = {0, 0};
        for (int k = 0; k < 4; k++) {
            IOReturn w = i2cWrite(0x61, rq, 2), rd = i2cRead(0x61, id2, 2);
            printf("\nXC5000 product id: 0x%02x%02x (w=%x r=%x status=0x%02x), expect 0x1388 when firmware is loaded\n", id2[0], id2[1], w, rd, i2cStatus());
        }
    }

    if (getenv("XCDIAG")) {
        uint16_t id = 0, v;
        xcRead(0x08, &id);
        int e1 = xcWrite(0x0d, 0), e2 = xcWrite(0x01, 0x8002), e3 = xcWrite(0x02, 0x00c0), e4 = xcWrite(0x05, 6144), e5 = xcWrite(0x03, (uint16_t)((473 - 1.75) / 0.015625));
        printf("\nXC5000 diag: id=0x%04x write status ioreturn: %x %x %x %x %x, i2c status 0x%02x\n", id, e1, e2, e3, e4, e5, i2cStatus());
        usleep(300000);
        for (uint8_t r = 0; r <= 0x0d; r++) { v = 0xffff; int e = xcRead(r, &v); printf("  xc reg 0x%02x = 0x%04x (e=%x)\n", r, v, e); }
    }

    if (capCh) { int alt = getenv("ALT") ? atoi(getenv("ALT")) : 4, ep = getenv("EP") ? (int)strtol(getenv("EP"), 0, 16) : 0x84; captureTS(capCh, getenv("SECS") ? atoi(getenv("SECS")) : 5, alt, ep, getenv("OUT") ? getenv("OUT") : "local/capture.ts"); captureStopRegs(); (*dev)->USBDeviceClose(dev); return 0; }

    if (doScan) { scanATSC(); (*dev)->USBDeviceClose(dev); return 0; }

    if (dumpAddr >= 0) {
        // Read 32 bytes at offsets 0 and 0x20, preceded by a 1-byte offset write (pointer set).
        printf("\nDump of 7-bit 0x%02x (offset write + read):\n", dumpAddr);
        for (int off = 0; off < 0x40; off += 0x10) {
            uint8_t o = (uint8_t)off, b[16] = {0};
            IOReturn w = i2cWrite(dumpAddr, &o, 1), rd = i2cRead(dumpAddr, b, 16);
            printf("  %02x: ", off);
            for (int j = 0; j < 16; j++) printf("%02x ", b[j]);
            printf(" (w=%x r=%x status=0x%02x)\n", w, rd, i2cStatus());
        }
        (*dev)->USBDeviceClose(dev);
        return 0;
    }

    if (noScan) { (*dev)->USBDeviceClose(dev); return 0; }
    printf("\nEEPROM @0x50 (first 64 bytes):\n");
    uint8_t off = 0, ee[64];
    if (i2cWrite(0x50, &off, 1) == kIOReturnSuccess && i2cRead(0x50, ee, 64) == kIOReturnSuccess) {
        for (int i = 0; i < 64; i += 16) {
            printf("  %02x:", i);
            for (int j = 0; j < 16; j++) printf(" %02x", ee[i + j]);
            printf("\n");
        }
        printf("  header: %02x %02x %02x %02x (Empia EEPROM magic is 1a eb 67 95)\n", ee[0], ee[1], ee[2], ee[3]);
    } else {
        printf("  read failed\n");
    }

    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 0;
}
