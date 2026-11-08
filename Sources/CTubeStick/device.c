// Device control path: Empia EM2883 bridge registers and I2C (XC5000 tuner, LGDT3304 demodulator) over IOKit.
// Register and I2C protocol details: docs/findings.md.
#include "device_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TS_VENDOR_ID 0x1d2c
#define TS_PRODUCT_ID 0x1012
#define I2C_XC5000 0x61
#define I2C_LGDT 0x0e

const char *ts_result_string(int r) {
    switch (r) {
        case TS_OK: return "ok";
        case TS_ERR_NOT_FOUND: return "no TubeStick Hybrid ATSC found";
        case TS_ERR_BUSY: return "another program has the stick open (quit TheTube and its helper, or other tools)";
        case TS_ERR_IO: return "USB or I2C transfer failed (unplug and replug the stick)";
        case TS_ERR_NO_FIRMWARE: return "the tuner needs its firmware file";
        case TS_ERR_BAD_ARG: return "bad argument";
        case TS_ERR_STREAM: return "could not start the video stream";
        default: return "unknown error";
    }
}

// ---- Bridge registers ----

static IOReturn ctl(ts_device *d, uint8_t dir, uint8_t req, uint16_t index, void *buf, uint16_t len) {
    IOUSBDevRequest r = {
        .bmRequestType = USBmakebmRequestType(dir, kUSBVendor, kUSBDevice),
        .bRequest = req, .wValue = 0, .wIndex = index, .wLength = len, .pData = buf,
    };
    return (*d->usb)->DeviceRequest(d->usb, &r);
}

int ts_reg_write(ts_device *d, uint8_t reg, uint8_t value) { return ctl(d, kUSBOut, 0x00, reg, &value, 1); }
int ts_reg_read(ts_device *d, uint8_t reg, uint8_t *value) { return ctl(d, kUSBIn, 0x00, reg, value, 1); }

static int i2cStatus(ts_device *d) { uint8_t s = 0xff; return ts_reg_read(d, 0x05, &s) ? -1 : s; }
// The bridge wants the 8-bit address form (7-bit address << 1) in wIndex.
static int i2cRead(ts_device *d, uint8_t addr7, uint8_t *buf, uint16_t n) { return ctl(d, kUSBIn, 0x02, (uint16_t)(addr7 << 1), buf, n); }
static int i2cWrite(ts_device *d, uint8_t addr7, const uint8_t *buf, uint16_t n) { return ctl(d, kUSBOut, 0x02, (uint16_t)(addr7 << 1), (void *)buf, n); }

// ---- XC5000 tuner ----

static int xcWrite(ts_device *d, uint8_t reg, uint16_t v) {
    uint8_t b[4] = {0, reg, (uint8_t)(v >> 8), (uint8_t)v};
    return i2cWrite(d, I2C_XC5000, b, 4);
}
static int xcRead(ts_device *d, uint8_t reg, uint16_t *v) {
    uint8_t rq[2] = {0, reg}, r[2] = {0, 0};
    int e = i2cWrite(d, I2C_XC5000, rq, 2);
    if (!e) e = i2cRead(d, I2C_XC5000, r, 2);
    *v = (uint16_t)((r[0] << 8) | r[1]);
    return e;
}

static int xcFirmwareLoaded(ts_device *d) {
    uint16_t id = 0;
    return xcRead(d, 0x08, &id) == 0 && id == 0x1388;
}

// The firmware file is a sequence of 16-bit big-endian lengths: 0xFFFF ends it, 0 is a reset action (skipped, the tuner
// is already out of reset), a set top bit is a delay in milliseconds, anything else is a register write of that many bytes
// (a 2-byte register header followed by data, sent in chunks of up to 62 bytes with the header repeated).
static int xcLoadFirmware(ts_device *d, const uint8_t *fw, size_t n) {
    size_t i = 0;
    while (i + 2 <= n) {
        unsigned len = (unsigned)((fw[i] << 8) | fw[i + 1]);
        i += 2;
        if (len == 0xFFFF) return TS_OK;
        if (len == 0) continue;
        if (len & 0x8000) { usleep((len & 0x7fff) * 1000); continue; }
        if (i + len > n || len < 2) return TS_ERR_BAD_ARG;
        const uint8_t *hdr = &fw[i], *data = &fw[i + 2];
        unsigned remain = len - 2;
        do {
            unsigned c = remain > 62 ? 62 : remain;
            uint8_t buf[64];
            buf[0] = hdr[0]; buf[1] = hdr[1];
            memcpy(buf + 2, data, c);
            if (i2cWrite(d, I2C_XC5000, buf, (uint16_t)(2 + c)) || i2cStatus(d) != 0) return TS_ERR_IO;
            data += c; remain -= c;
        } while (remain);
        i += len;
    }
    return TS_OK;
}

// ---- LGDT3304 demodulator ----

static int lgWrite(ts_device *d, uint16_t reg, uint8_t v) {
    uint8_t b[3] = {(uint8_t)(reg >> 8), (uint8_t)reg, v};
    return i2cWrite(d, I2C_LGDT, b, 3);
}
static uint8_t lgRead(ts_device *d, uint16_t reg) {
    uint8_t rq[2] = {(uint8_t)(reg >> 8), (uint8_t)reg}, v = 0;
    i2cWrite(d, I2C_LGDT, rq, 2);
    i2cRead(d, I2C_LGDT, &v, 1);
    return v;
}
static void lgRmw(ts_device *d, uint16_t reg, uint8_t andMask, uint8_t orMask) { lgWrite(d, reg, (uint8_t)((lgRead(d, reg) & andMask) | orMask)); }

// Reset and 8VSB initialization, transcribed from the original driver.
static void lgInitVSB(ts_device *d) {
    lgRmw(d, 0x0002, 0xfe, 0x00); usleep(1000);
    lgRmw(d, 0x0002, 0xff, 0x01); usleep(1000);
    lgRmw(d, 0x0000, 0xff, 0x03);
    lgWrite(d, 0x000d, 0x02); lgWrite(d, 0x000e, 0x02); lgWrite(d, 0x0012, 0x32); lgWrite(d, 0x0013, 0xc4);
    lgWrite(d, 0x0112, 0x17); lgWrite(d, 0x0113, 0x15); lgWrite(d, 0x0114, 0x18); lgWrite(d, 0x0115, 0xff);
    lgRmw(d, 0x0116, 0xf8, 0x04); lgRmw(d, 0x0214, 0xf0, 0x07);
    lgWrite(d, 0x0424, 0x8d); lgWrite(d, 0x0427, 0x12); lgWrite(d, 0x0428, 0x4f);
    lgWrite(d, 0x0308, 0x80); lgWrite(d, 0x0309, 0x00);
    lgRmw(d, 0x030d, 0xff, 0x10); lgRmw(d, 0x030d, 0xff, 0x04);
    lgRmw(d, 0x030e, 0xbf, 0x00); lgRmw(d, 0x030e, 0xfe, 0x00);
    lgWrite(d, 0x0314, 0xe1); lgWrite(d, 0x050e, 0x5b);
}

static int lgLocked(ts_device *d) { return !(lgRead(d, 0x0409) & 2); }

// ---- Public API ----

ts_device *ts_open(int *result) {
    int dummy; if (!result) result = &dummy;
    *result = TS_ERR_NOT_FOUND;
    int vid = TS_VENDOR_ID, pid = TS_PRODUCT_ID;
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid), p = CFNumberCreate(0, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);  // consumes m
    if (!svc) return NULL;

    IOCFPlugInInterface **plug = NULL; SInt32 score;
    IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (!plug) { *result = TS_ERR_IO; return NULL; }
    IOUSBDeviceInterface320 **usb = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID *)&usb);
    (*plug)->Release(plug);
    if (!usb) { *result = TS_ERR_IO; return NULL; }
    IOReturn r = (*usb)->USBDeviceOpen(usb);
    if (r) { (*usb)->Release(usb); *result = (r == kIOReturnExclusiveAccess) ? TS_ERR_BUSY : TS_ERR_IO; return NULL; }

    ts_device *d = calloc(1, sizeof *d);
    d->usb = usb;
    pthread_mutex_init(&d->lock, NULL);
    *result = TS_OK;
    return d;
}

void ts_close(ts_device *d) {
    if (!d) return;
    ts_stream_stop(d);
    if (d->usb) { (*d->usb)->USBDeviceClose(d->usb); (*d->usb)->Release(d->usb); }
    pthread_mutex_destroy(&d->lock);
    free(d);
}

int ts_reenumerate(ts_device *d) {
    if (!d) return TS_ERR_BAD_ARG;
    ts_stream_stop(d);
    IOReturn e = (*d->usb)->USBDeviceReEnumerate(d->usb, 0);
    (*d->usb)->USBDeviceClose(d->usb); (*d->usb)->Release(d->usb);
    d->usb = NULL;
    pthread_mutex_destroy(&d->lock);
    free(d);
    return e ? TS_ERR_IO : TS_OK;
}

int ts_prepare(ts_device *d, const uint8_t *firmware, size_t firmwareLength) {
    if (!d) return TS_ERR_BAD_ARG;
    pthread_mutex_lock(&d->lock);
    int rc = TS_OK;
    uint8_t chip = 0;
    if (ts_reg_read(d, 0x0a, &chip) != 0) { rc = TS_ERR_IO; goto out; }
    ts_reg_write(d, 0x06, 0x41);  // I2C clock 100 kHz with wait enabled
    if (!xcFirmwareLoaded(d)) {
        if (!firmware || firmwareLength < 4) { rc = TS_ERR_NO_FIRMWARE; goto out; }
        rc = xcLoadFirmware(d, firmware, firmwareLength);
        if (rc != TS_OK) goto out;
        usleep(100000);
        if (!xcFirmwareLoaded(d)) { rc = TS_ERR_IO; goto out; }
    }
    xcWrite(d, 0x00, 0x0000);  // xc_initialize: required after the firmware starts
    usleep(100000);
    lgInitVSB(d);
out:
    pthread_mutex_unlock(&d->lock);
    return rc;
}

int ts_rf_center_mhz(int ch) {
    if (ch >= 2 && ch <= 4) return 57 + 6 * (ch - 2);
    if (ch == 5) return 79;
    if (ch == 6) return 85;
    if (ch >= 7 && ch <= 13) return 177 + 6 * (ch - 7);
    if (ch >= 14 && ch <= 51) return 473 + 6 * (ch - 14);
    return 0;
}

int ts_tune(ts_device *d, int ch, int lockTimeoutMs) {
    if (!d) return TS_ERR_BAD_ARG;
    int center = ts_rf_center_mhz(ch);
    if (!center) return TS_ERR_BAD_ARG;
    pthread_mutex_lock(&d->lock);
    int locked = 0;
    lgInitVSB(d);
    // Tune the XC5000 for ATSC (6 MHz channel, IF 6.0 MHz): RF = center - 1.75 MHz.
    int e = xcWrite(d, 0x0d, 0);              // signal source: antenna
    e |= xcWrite(d, 0x01, 0x8002);            // video mode DTV6
    e |= xcWrite(d, 0x02, 0x00c0);            // audio mode DTV6
    e |= xcWrite(d, 0x05, (uint16_t)(6.0 * 1024));
    e |= xcWrite(d, 0x03, (uint16_t)((center - 1.75) / 0.015625));
    if (e) { pthread_mutex_unlock(&d->lock); return TS_ERR_IO; }
    for (int w = 0; w < 40; w++) { uint16_t busy = 1; xcRead(d, 0x09, &busy); if (!busy) break; usleep(20000); }
    pthread_mutex_unlock(&d->lock);
    // Poll for lock without holding the lock the whole time, so a running stream's controls are not starved.
    usleep(400000);
    for (int waited = 0;; waited += 100) {
        pthread_mutex_lock(&d->lock);
        locked = lgLocked(d);
        pthread_mutex_unlock(&d->lock);
        if (locked || waited >= lockTimeoutMs) break;
        usleep(100000);
    }
    return locked;
}

int ts_read_signal(ts_device *d, ts_signal *out) {
    if (!d || !out) return TS_ERR_BAD_ARG;
    pthread_mutex_lock(&d->lock);
    uint16_t level = 0, quality = 0;
    xcRead(d, 0x00, &level); xcRead(d, 0x06, &quality);
    out->locked = lgLocked(d);
    out->errorCount = ((unsigned)lgRead(d, 0x0417) << 16) | ((unsigned)lgRead(d, 0x0418) << 8) | lgRead(d, 0x0419);
    out->tunerLevel = level; out->tunerQuality = quality;
    pthread_mutex_unlock(&d->lock);
    return TS_OK;
}
