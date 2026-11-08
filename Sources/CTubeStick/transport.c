// MPEG-2 transport stream helpers: ATSC PSIP channel table (TVCT/CVCT) parsing, stream quality counters,
// and a single-program filter. Pure C, no hardware needed.
#include <stdlib.h>
#include <string.h>
#include "tubestick.h"

#define TS_PACKET 188
#define MAX_SERVICES 64
#define MAX_PROGRAMS 64
#define SECTION_MAX 4100

static uint32_t crc32mpeg(const uint8_t *d, size_t n) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        crc ^= (uint32_t)d[i] << 24;
        for (int b = 0; b < 8; b++) crc = (crc & 0x80000000u) ? (crc << 1) ^ 0x04C11DB7u : (crc << 1);
    }
    return crc;
}

// ---- Section reassembly (sections can span packets and several can start in one packet) ----

typedef struct {
    uint8_t buf[SECTION_MAX];
    int len;       // bytes collected
    int need;      // total section size (length field + 3), 0 when idle
} section_asm;

typedef void (*section_handler)(void *ctx, const uint8_t *section, int length);

static void sectionAppend(section_asm *s, const uint8_t *p, int n, section_handler h, void *ctx) {
    while (n > 0 && s->need) {
        int take = s->need - s->len;
        if (take > n) take = n;
        memcpy(s->buf + s->len, p, (size_t)take);
        s->len += take; p += take; n -= take;
        if (s->len >= s->need) {
            int total = s->need;
            s->need = 0; s->len = 0;
            h(ctx, s->buf, total);
        }
    }
}

// payload points at the TS payload; pusi is the payload_unit_start_indicator.
static void sectionFeed(section_asm *s, const uint8_t *payload, int len, int pusi, section_handler h, void *ctx) {
    if (len <= 0) return;
    if (!pusi) { if (s->need) sectionAppend(s, payload, len, h, ctx); return; }
    int pointer = payload[0];
    if (1 + pointer > len) { s->need = 0; s->len = 0; return; }
    if (s->need && pointer) sectionAppend(s, payload + 1, pointer, h, ctx);
    s->need = 0; s->len = 0;                      // anything unfinished before a new start is lost
    const uint8_t *p = payload + 1 + pointer;
    int n = len - 1 - pointer;
    while (n >= 3 && p[0] != 0xFF) {
        int total = (((p[1] & 0x0F) << 8) | p[2]) + 3;
        if (total > SECTION_MAX || total < 4) return;
        s->need = total; s->len = 0;
        int take = n < total ? n : total;
        sectionAppend(s, p, take, h, ctx);
        if (s->need) return;                      // continues in the next packet
        p += take; n -= take;
    }
}

// Returns the payload offset in a packet, or -1 if there is none.
static int payloadOffset(const uint8_t *pkt) {
    int afc = (pkt[3] >> 4) & 3;
    if (!(afc & 1)) return -1;
    int off = 4;
    if (afc & 2) off += 1 + pkt[4];
    return off >= TS_PACKET ? -1 : off;
}

// ---- Analyzer ----

struct ts_analyzer {
    uint8_t carry[TS_PACKET];
    int carryLen;
    int lastCC[8192];
    ts_quality quality;
    section_asm pat, psip;
    int transportId;
    int patPrograms, patPmt[MAX_PROGRAMS];
    uint8_t vctSeen[32];
    int vctLast, vctTsid;
    int nServices;
    ts_service services[MAX_SERVICES];
    int haveVct;
};

ts_analyzer *ts_analyzer_new(void) {
    ts_analyzer *a = calloc(1, sizeof *a);
    ts_analyzer_reset(a);
    return a;
}
void ts_analyzer_free(ts_analyzer *a) { free(a); }

void ts_analyzer_reset(ts_analyzer *a) {
    memset(a, 0, sizeof *a);
    for (int i = 0; i < 8192; i++) a->lastCC[i] = -1;
    a->transportId = -1; a->vctLast = -1; a->vctTsid = -1;
}

static void utf16ToUtf8(const uint8_t *src, int units, char *out, size_t outSize) {
    size_t o = 0;
    for (int i = 0; i < units; i++) {
        unsigned c = (unsigned)((src[2 * i] << 8) | src[2 * i + 1]);
        if (!c) break;
        if (c >= 0xD800 && c <= 0xDFFF) c = '?';
        if (c < 0x80) { if (o + 1 < outSize) out[o++] = (char)c; }
        else if (c < 0x800) { if (o + 2 < outSize) { out[o++] = (char)(0xC0 | (c >> 6)); out[o++] = (char)(0x80 | (c & 0x3F)); } }
        else { if (o + 3 < outSize) { out[o++] = (char)(0xE0 | (c >> 12)); out[o++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[o++] = (char)(0x80 | (c & 0x3F)); } }
    }
    out[o] = 0;
}

static void handlePat(void *ctx, const uint8_t *s, int len) {
    ts_analyzer *a = ctx;
    if (s[0] != 0x00 || !(s[1] & 0x80) || len < 12 || crc32mpeg(s, (size_t)len) != 0) return;
    a->transportId = (s[3] << 8) | s[4];
    int n = 0;
    for (int i = 8; i + 4 <= len - 4 && n < MAX_PROGRAMS; i += 4) {
        int prog = (s[i] << 8) | s[i + 1], pid = ((s[i + 2] & 0x1F) << 8) | s[i + 3];
        if (prog != 0) a->patPmt[n++] = (prog << 16) | pid;
    }
    a->patPrograms = n;
}

static void handlePsip(void *ctx, const uint8_t *s, int len) {
    ts_analyzer *a = ctx;
    if ((s[0] != 0xC8 && s[0] != 0xC9) || !(s[1] & 0x80) || len < 14) return;
    if (!(s[5] & 1)) return;                                    // not current
    if (crc32mpeg(s, (size_t)len) != 0) return;
    int tsid = (s[3] << 8) | s[4], secNo = s[6], last = s[7], num = s[9];
    if (tsid != a->vctTsid || last != a->vctLast) {              // new table: start over
        memset(a->vctSeen, 0, sizeof a->vctSeen); a->nServices = 0; a->haveVct = 0;
        a->vctTsid = tsid; a->vctLast = last;
    }
    int p = 10, end = len - 4;
    for (int i = 0; i < num; i++) {
        if (p + 32 > end) return;
        const uint8_t *c = s + p;
        ts_service sv; memset(&sv, 0, sizeof sv);
        utf16ToUtf8(c, 7, sv.name, sizeof sv.name);
        sv.major = (uint16_t)(((c[14] & 0x0F) << 6) | (c[15] >> 2));
        sv.minor = (uint16_t)(((c[15] & 0x03) << 8) | c[16]);
        sv.program = (uint16_t)((c[24] << 8) | c[25]);
        sv.hidden = (c[26] >> 4) & 1;
        sv.serviceType = c[27] & 0x3F;
        int known = 0;
        for (int k = 0; k < a->nServices; k++) if (a->services[k].major == sv.major && a->services[k].minor == sv.minor) known = 1;
        if (!known && a->nServices < MAX_SERVICES) a->services[a->nServices++] = sv;
        p += 32 + (((c[30] & 3) << 8) | c[31]);
    }
    a->vctSeen[secNo >> 3] |= (uint8_t)(1 << (secNo & 7));
    int all = 1;
    for (int k = 0; k <= a->vctLast; k++) if (!(a->vctSeen[k >> 3] & (1 << (k & 7)))) all = 0;
    a->haveVct = all;
}

static void analyzePacket(ts_analyzer *a, const uint8_t *p) {
    ts_quality *q = &a->quality;
    q->packets++;
    int pid = ((p[1] & 0x1F) << 8) | p[2];
    if (pid == 0x1FFF) { q->nullPackets++; return; }
    if (p[1] & 0x80) q->errorFlagged++;
    int afc = (p[3] >> 4) & 3, cc = p[3] & 15;
    int discont = (afc & 2) && p[4] > 0 && (p[5] & 0x80);
    if ((afc & 1) && !(p[1] & 0x80)) {
        int last = a->lastCC[pid];
        if (last >= 0 && !discont && cc != last) {              // same cc once is a legal duplicate
            int gap = (cc - last - 1) & 15;
            q->lost += (unsigned)gap;
        }
        a->lastCC[pid] = cc;
    }
    if ((p[1] & 0x80)) return;                                    // do not trust damaged packets for tables
    if (pid == 0 || pid == 0x1FFB) {
        int off = payloadOffset(p);
        if (off < 0) return;
        if (pid == 0) sectionFeed(&a->pat, p + off, TS_PACKET - off, (p[1] >> 6) & 1, handlePat, a);
        else sectionFeed(&a->psip, p + off, TS_PACKET - off, (p[1] >> 6) & 1, handlePsip, a);
    }
}

void ts_analyzer_feed(ts_analyzer *a, const uint8_t *d, size_t n) {
    size_t i = 0;
    while (i < n) {
        if (a->carryLen) {                                        // finish a packet split across calls
            size_t take = (size_t)(TS_PACKET - a->carryLen);
            if (take > n - i) take = n - i;
            memcpy(a->carry + a->carryLen, d + i, take);
            a->carryLen += (int)take; i += take;
            if (a->carryLen == TS_PACKET) { analyzePacket(a, a->carry); a->carryLen = 0; }
            continue;
        }
        if (d[i] != 0x47 || (i + TS_PACKET < n && d[i + TS_PACKET] != 0x47)) { a->quality.syncLosses++; i++; continue; }
        if (i + TS_PACKET > n) { memcpy(a->carry, d + i, n - i); a->carryLen = (int)(n - i); return; }
        analyzePacket(a, d + i);
        i += TS_PACKET;
    }
}

int ts_analyzer_has_services(const ts_analyzer *a) { return a->haveVct; }
int ts_analyzer_transport_id(const ts_analyzer *a) { return a->transportId; }
void ts_analyzer_quality(const ts_analyzer *a, ts_quality *out) { *out = a->quality; }

static int cmpService(const void *x, const void *y) {
    const ts_service *a = x, *b = y;
    if (a->major != b->major) return a->major < b->major ? -1 : 1;
    return a->minor < b->minor ? -1 : a->minor > b->minor;
}
int ts_analyzer_services(const ts_analyzer *a, ts_service *out, int max) {
    int n = a->nServices < max ? a->nServices : max;
    if (out && n > 0) { memcpy(out, a->services, (size_t)n * sizeof *out); qsort(out, (size_t)n, sizeof *out, cmpService); }
    return a->nServices;
}

// ---- Program filter ----

struct ts_program_filter {
    uint16_t program;
    ts_filter_output output;
    void *context;
    section_asm pat, pmt;
    int pmtPid;                 // 0 until the PAT names it
    uint8_t keep[8192];
    int patTsid;
    uint8_t patCC;
    uint8_t out[TS_PACKET * 64];
    size_t outLen;
};

ts_program_filter *ts_program_filter_new(uint16_t program, ts_filter_output output, void *context) {
    ts_program_filter *f = calloc(1, sizeof *f);
    f->program = program; f->output = output; f->context = context;
    return f;
}
void ts_program_filter_free(ts_program_filter *f) { free(f); }

static void flushOut(ts_program_filter *f) {
    if (f->outLen) { f->output(f->out, f->outLen, f->context); f->outLen = 0; }
}
static void emit(ts_program_filter *f, const uint8_t *pkt) {
    memcpy(f->out + f->outLen, pkt, TS_PACKET);
    f->outLen += TS_PACKET;
    if (f->outLen == sizeof f->out) flushOut(f);
}

static void filterPat(void *ctx, const uint8_t *s, int len) {
    ts_program_filter *f = ctx;
    if (s[0] != 0x00 || !(s[1] & 0x80) || len < 12 || crc32mpeg(s, (size_t)len) != 0) return;
    f->patTsid = (s[3] << 8) | s[4];
    for (int i = 8; i + 4 <= len - 4; i += 4) {
        int prog = (s[i] << 8) | s[i + 1], pid = ((s[i + 2] & 0x1F) << 8) | s[i + 3];
        if (prog == f->program) { f->pmtPid = pid; f->keep[pid] = 1; }
    }
}

static void filterPmt(void *ctx, const uint8_t *s, int len) {
    ts_program_filter *f = ctx;
    if (s[0] != 0x02 || len < 16 || crc32mpeg(s, (size_t)len) != 0) return;
    if (((s[3] << 8) | s[4]) != f->program) return;
    int pcr = ((s[8] & 0x1F) << 8) | s[9];
    int infoLen = ((s[10] & 0x0F) << 8) | s[11];
    f->keep[pcr] = 1;
    for (int i = 12 + infoLen; i + 5 <= len - 4;) {
        int pid = ((s[i + 1] & 0x1F) << 8) | s[i + 2];
        f->keep[pid] = 1;
        i += 5 + (((s[i + 3] & 0x0F) << 8) | s[i + 4]);
    }
}

static void emitPat(ts_program_filter *f) {
    uint8_t pkt[TS_PACKET]; memset(pkt, 0xFF, sizeof pkt);
    uint8_t sec[16];
    sec[0] = 0x00; sec[1] = 0xB0; sec[2] = 13;                     // section_length = 13
    sec[3] = (uint8_t)(f->patTsid >> 8); sec[4] = (uint8_t)f->patTsid;
    sec[5] = 0xC1; sec[6] = 0; sec[7] = 0;
    sec[8] = (uint8_t)(f->program >> 8); sec[9] = (uint8_t)f->program;
    sec[10] = (uint8_t)(0xE0 | (f->pmtPid >> 8)); sec[11] = (uint8_t)f->pmtPid;
    uint32_t crc = crc32mpeg(sec, 12);
    sec[12] = (uint8_t)(crc >> 24); sec[13] = (uint8_t)(crc >> 16); sec[14] = (uint8_t)(crc >> 8); sec[15] = (uint8_t)crc;
    pkt[0] = 0x47; pkt[1] = 0x40; pkt[2] = 0x00; pkt[3] = (uint8_t)(0x10 | (f->patCC++ & 15)); pkt[4] = 0;
    memcpy(pkt + 5, sec, 16);
    emit(f, pkt);
}

void ts_program_filter_feed(ts_program_filter *f, const uint8_t *d, size_t n) {
    size_t i = 0;
    while (i + TS_PACKET <= n) {
        if (d[i] != 0x47) { i++; continue; }
        const uint8_t *p = d + i;
        i += TS_PACKET;
        int pid = ((p[1] & 0x1F) << 8) | p[2];
        int pusi = (p[1] >> 6) & 1;
        if (pid == 0) {
            int off = payloadOffset(p);
            if (off >= 0 && !(p[1] & 0x80)) sectionFeed(&f->pat, p + off, TS_PACKET - off, pusi, filterPat, f);
            if (f->pmtPid && pusi) emitPat(f);                      // one rewritten PAT per original PAT start
            continue;
        }
        if (!f->keep[pid]) continue;
        if (pid == f->pmtPid) {
            int off = payloadOffset(p);
            if (off >= 0 && !(p[1] & 0x80)) sectionFeed(&f->pmt, p + off, TS_PACKET - off, pusi, filterPmt, f);
        }
        emit(f, p);
    }
    flushOut(f);
}
