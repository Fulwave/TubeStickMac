// tshost.m: isochronous transport-stream capture with Apple's IOUSBHost framework (macOS 12+).
// IOUSBHostIsochronousTransaction describes ONE microframe (125 us), so we can read all eight
// 752-byte slots per millisecond. The legacy IOUSBInterface API only collected one per millisecond.
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <time.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static volatile sig_atomic_t g_stop;
static void onSignal(int s) { g_stop = 1; }

#define NTX 512     // microframes per transfer (64 ms)
#define NXFER 8     // transfers kept in flight
static NSMutableData *datas[NXFER];
static IOUSBHostIsochronousTransaction *lists[NXFER];
static unsigned long hist[4];  // 0 B, short, full, other

int tshost_capture(int vid, int pid, int alt, int ep, int seconds, const char *path, void (*afterAlt)(void)) {
    @autoreleasepool {
        // Find the IOUSBHostInterface that belongs to our device.
        io_iterator_t it; io_service_t isvc = 0;
        if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOUSBHostInterface"), &it)) return 1;
        for (io_service_t s; (s = IOIteratorNext(it));) {
            io_service_t parent = 0; IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent);
            int v = -1, p = -1;
            CFTypeRef a = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("idVendor"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
            CFTypeRef b = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("idProduct"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
            if (a) { CFNumberGetValue(a, kCFNumberIntType, &v); CFRelease(a); }
            if (b) { CFNumberGetValue(b, kCFNumberIntType, &p); CFRelease(b); }
            if (v == vid && p == pid) { isvc = s; break; }
            IOObjectRelease(s);
        }
        if (!isvc) { printf("tshost: IOUSBHostInterface for %04x:%04x not found\n", vid, pid); return 1; }

        NSError *err = nil;
        IOUSBHostInterface *iface = [[IOUSBHostInterface alloc] initWithIOService:isvc options:IOUSBHostObjectInitOptionsNone queue:nil error:&err interestHandler:nil];
        if (!iface) { printf("tshost: could not open interface: %s\n", err.localizedDescription.UTF8String); return 1; }
        if (![iface selectAlternateSetting:(NSUInteger)alt error:&err]) { printf("tshost: selectAlternateSetting(%d) failed: %s\n", alt, err.localizedDescription.UTF8String); return 1; }
        printf("tshost: alternate setting %d selected\n", alt);
        if (afterAlt) afterAlt();

        IOUSBHostPipe *pipe = [iface copyPipeWithAddress:(NSUInteger)ep error:&err];
        if (!pipe) { printf("tshost: no pipe 0x%02x: %s\n", ep, err.localizedDescription.UTF8String); return 1; }
        const IOUSBEndpointDescriptor *ed = &pipe.descriptors->descriptor;
        uint32_t mp = (uint32_t)(ed->wMaxPacketSize & 0x7ff) * (1 + ((ed->wMaxPacketSize >> 11) & 3));
        printf("tshost: pipe 0x%02x, %u bytes per microframe, interval %u\n", ep, mp, ed->bInterval);

        // Output: a file (OUT=path, or OUT=- for none) and/or live UDP (UDP=host:port, 7 TS packets per datagram).
        FILE *out = (path && strcmp(path, "-")) ? fopen(path, "wb") : NULL;
        int usock = -1; struct sockaddr_in udst; memset(&udst, 0, sizeof udst);
        if (getenv("UDP")) {
            char hp[128]; strlcpy(hp, getenv("UDP"), sizeof hp); char *colon = strrchr(hp, ':');
            if (colon) { *colon = 0; udst.sin_family = AF_INET; udst.sin_port = htons((uint16_t)atoi(colon + 1)); udst.sin_addr.s_addr = inet_addr(hp); usock = socket(AF_INET, SOCK_DGRAM, 0); }
            if (usock >= 0) printf("tshost: live output to udp://%s:%d\n", hp, atoi(colon + 1));
        }
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
        static uint8_t ubuf[1316 * 2]; __block size_t ulen = 0;
        __block unsigned long bytes = 0, sync = 0, zero = 0, tx = 0, errs = 0, callbacks = 0;
        __block BOOL stop = NO;
        void (^__block submit)(int);
        void (^__block done)(int);
        submit = ^(int k) {
            for (int i = 0; i < NTX; i++) { lists[k][i].status = kIOReturnInvalid; lists[k][i].requestCount = mp; lists[k][i].offset = (uint32_t)i * mp; lists[k][i].completeCount = 0; lists[k][i].options = IOUSBHostIsochronousTransactionOptionsNone; }
            NSError *e = nil;
            if (![pipe enqueueIORequestWithData:datas[k] transactionList:lists[k] transactionListCount:NTX firstFrameNumber:0 options:IOUSBHostIsochronousTransferOptionsNone error:&e completionHandler:^(IOReturn status, IOUSBHostIsochronousTransaction *l) { done(k); }]) { errs++; if (errs < 4) printf("tshost: enqueue failed: %s\n", e.localizedDescription.UTF8String); }
        };
        done = ^(int k) {
            callbacks++;
            for (int i = 0; i < NTX; i++) {
                uint32_t n = lists[k][i].completeCount; tx++;
                hist[n == 0 ? 0 : n < mp ? 1 : n == mp ? 2 : 3]++;
                if (n == 0) { zero++; continue; }
                const uint8_t *d = (const uint8_t *)datas[k].bytes + lists[k][i].offset;
                if (out) fwrite(d, 1, n, out);
                bytes += n;
                if (usock >= 0) {
                    if (ulen + n > sizeof ubuf) ulen = 0;
                    memcpy(ubuf + ulen, d, n); ulen += n;
                    while (ulen >= 1316) { sendto(usock, ubuf, 1316, 0, (struct sockaddr *)&udst, sizeof udst); memmove(ubuf, ubuf + 1316, ulen - 1316); ulen -= 1316; }
                }
                for (uint32_t j = 0; j + 188 <= n; j += 188) if (d[j] == 0x47) sync++;
            }
            if (!stop) submit(k);
        };
        for (int k = 0; k < NXFER; k++) {
            datas[k] = [iface ioDataWithCapacity:(NSUInteger)mp * NTX error:&err];
            if (!datas[k]) { printf("tshost: ioData failed: %s\n", err.localizedDescription.UTF8String); return 1; }
            lists[k] = (IOUSBHostIsochronousTransaction *)calloc(NTX, sizeof(IOUSBHostIsochronousTransaction));
            submit(k);
        }
        time_t t0 = time(NULL);
        while (time(NULL) - t0 < seconds && !g_stop) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        stop = YES;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        if (out) fclose(out);
        if (usock >= 0) close(usock);
        printf("tshost: callbacks %lu, microframes %lu: empty %lu | short %lu | full(%u B) %lu | other %lu, enqueue errors %lu\n", callbacks, tx, hist[0], hist[1], mp, hist[2], hist[3], errs);
        printf("captured %lu bytes, %lu aligned 0x47 sync bytes -> %s\n", bytes, sync, path);
        [iface selectAlternateSetting:0 error:nil];  // back to the idle setting (no isochronous bandwidth reserved)
        [iface destroy];
    }
    return 0;
}
