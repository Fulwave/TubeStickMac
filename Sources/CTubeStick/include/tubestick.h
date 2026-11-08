// CTubeStick: control and capture for the equinux TubeStick Hybrid ATSC (Empia EM2883, USB 1d2c:1012)
// plus a small MPEG-TS / ATSC PSIP parser. See docs/findings.md for how the hardware protocol was worked out.
#ifndef TUBESTICK_H
#define TUBESTICK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------------------------
// Device
// ---------------------------------------------------------------------------------------------

typedef struct ts_device ts_device;

typedef enum {
    TS_OK = 0,
    TS_ERR_NOT_FOUND = -1,     // no stick attached
    TS_ERR_BUSY = -2,          // another process has the stick open
    TS_ERR_IO = -3,            // a USB or I2C transfer failed (the stick may need a replug)
    TS_ERR_NO_FIRMWARE = -4,   // the tuner needs firmware and none was supplied
    TS_ERR_BAD_ARG = -5,
    TS_ERR_STREAM = -6,        // the isochronous stream could not be started
} ts_result;

const char *ts_result_string(int result);

// Opens the first attached TubeStick Hybrid ATSC. On failure returns NULL and stores the reason in *result.
ts_device *ts_open(int *result);
void ts_close(ts_device *dev);

// Software unplug and replug (re-enumerates the stick on the bus). Closes the device; wait a few seconds, then ts_open again.
int ts_reenumerate(ts_device *dev);

// Sets up the I2C bus, loads the XC5000 tuner firmware if the tuner does not already have it, and initializes the
// ATSC demodulator. `firmware` is the XC5000 I2C sequence (the format of linux-firmware's dvb-fe-xc5000-1.6.114.fw);
// it may be NULL if the tuner already has its firmware loaded. Never reloads firmware into a running tuner:
// that has been seen to hang the stick.
int ts_prepare(ts_device *dev, const uint8_t *firmware, size_t firmwareLength);

// ---------------------------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------------------------

// Center frequency in MHz of a US ATSC RF channel (2-51), or 0 for an invalid channel.
int ts_rf_center_mhz(int rfChannel);

typedef struct {
    int locked;               // the 8VSB demodulator reports lock
    unsigned errorCount;      // demodulator packet error counter
    unsigned tunerLevel;      // XC5000 ADC envelope level
    unsigned tunerQuality;    // XC5000 quality estimate (register 0x06)
} ts_signal;

// Tunes to a US over-the-air ATSC channel and waits up to lockTimeoutMs for the demodulator to lock.
// Returns 1 if locked, 0 if not, negative on error. Safe to call while a stream is running.
int ts_tune(ts_device *dev, int rfChannel, int lockTimeoutMs);
int ts_read_signal(ts_device *dev, ts_signal *out);

// ---------------------------------------------------------------------------------------------
// Transport stream
// ---------------------------------------------------------------------------------------------

// Called on a background queue with whole 188-byte MPEG-TS packets (length is a multiple of 188). Keep it fast.
typedef void (*ts_data_callback)(const uint8_t *packets, size_t length, void *context);

// Starts the isochronous stream (about 2.4 MB/s at full load). The tuner must already be tuned.
int ts_stream_start(ts_device *dev, ts_data_callback callback, void *context);
// Stops the stream, returns the stick to its idle USB setting and disables the bridge FIFO. Blocks until the callback
// can no longer fire. Always call this before closing the device or exiting: a stream left running can hang the stick.
void ts_stream_stop(ts_device *dev);
int ts_stream_running(ts_device *dev);
// Statistics since the stream started.
typedef struct { unsigned long long bytes; unsigned long long microframes; unsigned long long emptyMicroframes; unsigned long long errors; } ts_stream_stats;
void ts_stream_get_stats(ts_device *dev, ts_stream_stats *out);

// ---------------------------------------------------------------------------------------------
// MPEG-TS and ATSC PSIP parsing (no hardware needed)
// ---------------------------------------------------------------------------------------------

typedef struct {
    uint16_t major;           // virtual channel, e.g. 7 in "7.1"
    uint16_t minor;           // subchannel, e.g. 1 in "7.1"
    uint16_t program;         // MPEG program number inside this transport stream
    uint8_t serviceType;      // 2 = digital TV, 3 = audio only, 4 = data
    uint8_t hidden;
    char name[24];            // short name, UTF-8 (up to 7 characters)
} ts_service;

typedef struct ts_analyzer ts_analyzer;

ts_analyzer *ts_analyzer_new(void);
void ts_analyzer_free(ts_analyzer *a);
void ts_analyzer_reset(ts_analyzer *a);
// Feeds TS packets (a multiple of 188 bytes; stray bytes are resynchronized on the 0x47 sync byte).
void ts_analyzer_feed(ts_analyzer *a, const uint8_t *data, size_t length);
// 1 once a complete, CRC-checked channel table (TVCT or CVCT) has been seen.
int ts_analyzer_has_services(const ts_analyzer *a);
// Copies up to `max` services (sorted by major, minor) and returns how many there are.
int ts_analyzer_services(const ts_analyzer *a, ts_service *out, int max);
// Transport stream id from the PAT, or -1 if not seen yet.
int ts_analyzer_transport_id(const ts_analyzer *a);

typedef struct {
    unsigned long long packets;       // 188-byte packets seen
    unsigned long long syncLosses;    // bytes skipped to resynchronize
    unsigned long long errorFlagged;  // packets with the transport_error_indicator set
    unsigned long long lost;          // estimated lost packets from continuity counter jumps
    unsigned long long nullPackets;
} ts_quality;
void ts_analyzer_quality(const ts_analyzer *a, ts_quality *out);

// Reduces a multi-program stream to one program (for a player that cannot choose): keeps the PAT (rewritten to list
// only that program), its PMT, and the PMT's streams; drops everything else. Output is whole TS packets.
typedef struct ts_program_filter ts_program_filter;
typedef void (*ts_filter_output)(const uint8_t *packets, size_t length, void *context);
ts_program_filter *ts_program_filter_new(uint16_t program, ts_filter_output output, void *context);
void ts_program_filter_free(ts_program_filter *f);
void ts_program_filter_feed(ts_program_filter *f, const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif
