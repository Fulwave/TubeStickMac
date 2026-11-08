// Isochronous transport stream capture with Apple's IOUSBHost framework (macOS 12+).
// IOUSBHostIsochronousTransaction describes ONE microframe (125 us), so all eight 752-byte slots per millisecond are
// collected. The older IOUSBInterface API only serviced one microframe per millisecond (about 1/8 of the stream).
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "device_internal.h"

#define TS_STREAM_ALT 4        // alternate setting that carries the digital stream
#define TS_STREAM_ENDPOINT 0x84
#define NTX 512                // microframes per transfer (64 ms)
#define NXFER 8                // transfers kept in flight (about 0.5 s of buffering)

@interface TSStream : NSObject {
@public
    IOUSBHostInterface *iface;
    IOUSBHostPipe *pipe;
    dispatch_queue_t queue;
    dispatch_group_t inflight;
    NSMutableData *datas[NXFER];
    IOUSBHostIsochronousTransaction *lists[NXFER];
    uint32_t maxPerMicroframe;
    ts_data_callback callback;
    void *context;
    atomic_bool stopping;
    ts_stream_stats stats;
}
- (void)submit:(int)k;
@end

@implementation TSStream
- (void)submit:(int)k {
    for (int i = 0; i < NTX; i++) {
        lists[k][i].status = kIOReturnInvalid;
        lists[k][i].requestCount = maxPerMicroframe;
        lists[k][i].offset = (uint32_t)i * maxPerMicroframe;
        lists[k][i].completeCount = 0;
        lists[k][i].options = IOUSBHostIsochronousTransactionOptionsNone;
    }
    NSError *e = nil;
    dispatch_group_enter(inflight);
    BOOL ok = [pipe enqueueIORequestWithData:datas[k] transactionList:lists[k] transactionListCount:NTX
                            firstFrameNumber:0 options:IOUSBHostIsochronousTransferOptionsNone error:&e
                           completionHandler:^(IOReturn status, IOUSBHostIsochronousTransaction *l) {
        [self completed:k];
        dispatch_group_leave(self->inflight);
    }];
    if (!ok) {
        stats.errors++;
        dispatch_group_leave(inflight);
    }
}

- (void)completed:(int)k {
    for (int i = 0; i < NTX; i++) {
        uint32_t n = lists[k][i].completeCount;
        stats.microframes++;
        if (n == 0) { stats.emptyMicroframes++; continue; }
        stats.bytes += n;
        // Each microframe carries whole 188-byte TS packets; pass on only the whole packets.
        n -= n % 188;
        if (n && callback) callback((const uint8_t *)datas[k].bytes + lists[k][i].offset, n, context);
    }
    if (!atomic_load(&stopping)) [self submit:k];
}
@end

static io_service_t findHostInterface(int vid, int pid) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it)) return 0;
    io_service_t found = 0;
    for (io_service_t s; (s = IOIteratorNext(it));) {
        int v = -1, p = -1;
        CFTypeRef a = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("idVendor"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        CFTypeRef b = IORegistryEntrySearchCFProperty(s, kIOServicePlane, CFSTR("idProduct"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (a) { CFNumberGetValue(a, kCFNumberIntType, &v); CFRelease(a); }
        if (b) { CFNumberGetValue(b, kCFNumberIntType, &p); CFRelease(b); }
        if (v == vid && p == pid) { found = s; break; }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

// Digital stream setup of the original driver (chip id 0x24 path), then the Linux em28xx_capture_start() sequence.
static void bridgeStreamSetup(ts_device *d) {
    pthread_mutex_lock(&d->lock);
    ts_reg_write(d, 0x1c, 0x00); ts_reg_write(d, 0x1d, 0x20); ts_reg_write(d, 0x1e, 0x20); ts_reg_write(d, 0x1f, 0x20);
    uint8_t r1b = 0;
    ts_reg_read(d, 0x1b, &r1b); ts_reg_write(d, 0x1b, r1b & ~0x01);
    ts_reg_read(d, 0x1b, &r1b); ts_reg_write(d, 0x1b, r1b & ~0x02);
    ts_reg_write(d, 0x12, 0x37);
    pthread_mutex_unlock(&d->lock);
}
static void bridgeCaptureStart(ts_device *d) {
    pthread_mutex_lock(&d->lock);
    uint8_t r0c = 0;
    ts_reg_read(d, 0x0c, &r0c); ts_reg_write(d, 0x0c, r0c | 0x10); ts_reg_write(d, 0x48, 0x00); ts_reg_write(d, 0x12, 0x37);
    usleep(10000);
    pthread_mutex_unlock(&d->lock);
}
// A stream left enabled with nobody reading it overflows the bridge FIFO and the stick stops answering.
static void bridgeCaptureStop(ts_device *d) {
    pthread_mutex_lock(&d->lock);
    uint8_t r0c = 0;
    ts_reg_read(d, 0x0c, &r0c); ts_reg_write(d, 0x0c, r0c & ~0x10); ts_reg_write(d, 0x12, 0x27);
    pthread_mutex_unlock(&d->lock);
}

int ts_stream_start(ts_device *d, ts_data_callback callback, void *context) {
    if (!d) return TS_ERR_BAD_ARG;
    if (d->stream) return TS_OK;
    @autoreleasepool {
        bridgeStreamSetup(d);
        (*d->usb)->SetConfiguration(d->usb, 1);

        io_service_t isvc = findHostInterface(0x1d2c, 0x1012);
        if (!isvc) return TS_ERR_STREAM;
        NSError *err = nil;
        TSStream *s = [TSStream new];
        s->queue = dispatch_queue_create("com.fulwave.tubestick.stream", DISPATCH_QUEUE_SERIAL);
        s->iface = [[IOUSBHostInterface alloc] initWithIOService:isvc options:IOUSBHostObjectInitOptionsNone queue:s->queue error:&err interestHandler:nil];
        IOObjectRelease(isvc);
        if (!s->iface) return TS_ERR_STREAM;
        if (![s->iface selectAlternateSetting:TS_STREAM_ALT error:&err]) { [s->iface destroy]; return TS_ERR_STREAM; }
        bridgeCaptureStart(d);

        s->pipe = [s->iface copyPipeWithAddress:TS_STREAM_ENDPOINT error:&err];
        if (!s->pipe) { bridgeCaptureStop(d); [s->iface destroy]; return TS_ERR_STREAM; }
        const IOUSBEndpointDescriptor *ed = &s->pipe.descriptors->descriptor;
        s->maxPerMicroframe = (uint32_t)(ed->wMaxPacketSize & 0x7ff) * (1 + ((ed->wMaxPacketSize >> 11) & 3));
        s->callback = callback; s->context = context;
        s->inflight = dispatch_group_create();
        atomic_init(&s->stopping, false);
        for (int k = 0; k < NXFER; k++) {
            s->datas[k] = [s->iface ioDataWithCapacity:(NSUInteger)s->maxPerMicroframe * NTX error:&err];
            if (!s->datas[k]) {
                atomic_store(&s->stopping, true);
                [s->pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
                dispatch_group_wait(s->inflight, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
                bridgeCaptureStop(d); [s->iface destroy];
                for (int j = 0; j < k; j++) free(s->lists[j]);
                return TS_ERR_STREAM;
            }
            s->lists[k] = calloc(NTX, sizeof(IOUSBHostIsochronousTransaction));
            [s submit:k];
        }
        d->stream = (void *)CFBridgingRetain(s);
    }
    return TS_OK;
}

void ts_stream_stop(ts_device *d) {
    if (!d || !d->stream) return;
    @autoreleasepool {
        TSStream *s = (TSStream *)CFBridgingRelease(d->stream);
        d->stream = NULL;
        atomic_store(&s->stopping, true);
        [s->pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        dispatch_group_wait(s->inflight, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        s->callback = NULL;
        bridgeCaptureStop(d);
        [s->iface selectAlternateSetting:0 error:nil];  // idle setting: no isochronous bandwidth reserved
        [s->iface destroy];
        for (int k = 0; k < NXFER; k++) free(s->lists[k]);
        // The stats of the stopped stream stay readable through the last snapshot only while streaming; clear state here.
    }
}

int ts_stream_running(ts_device *d) { return d && d->stream != NULL; }

void ts_stream_get_stats(ts_device *d, ts_stream_stats *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!d || !d->stream) return;
    TSStream *s = (__bridge TSStream *)d->stream;
    *out = s->stats;
}
