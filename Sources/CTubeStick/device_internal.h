#ifndef TS_DEVICE_INTERNAL_H
#define TS_DEVICE_INTERNAL_H

#include <IOKit/usb/IOUSBLib.h>
#include <pthread.h>
#include "tubestick.h"

struct ts_device {
    IOUSBDeviceInterface320 **usb;
    pthread_mutex_t lock;   // serializes bridge register and I2C access
    void *stream;           // stream state (stream.m), NULL when not streaming
};

int ts_reg_write(ts_device *d, uint8_t reg, uint8_t value);
int ts_reg_read(ts_device *d, uint8_t reg, uint8_t *value);

#endif
