#!/usr/bin/env python3
"""Check an MPEG transport stream capture: sync, losses (continuity counters), error flags, programs.
Usage: python3 -I tools/tsanalyze.py capture.ts"""
import collections, sys
d = open(sys.argv[1], "rb").read(); n = len(d) // 188
bad = last = tei = 0; lastcc = {}; got = collections.Counter(); lost = collections.Counter(); pids = collections.Counter()
for i in range(n):
    p = d[i*188:(i+1)*188]
    if p[0] != 0x47: bad += 1; continue
    pid = ((p[1] & 0x1f) << 8) | p[2]; pids[pid] += 1
    if p[1] & 0x80: tei += 1
    if pid == 0x1fff or not (p[3] & 0x10): continue
    got[pid] += 1; cc = p[3] & 15
    if pid in lastcc:
        dl = (cc - lastcc[pid]) & 15
        if dl > 1: lost[pid] += dl - 1
    lastcc[pid] = cc
tg, tl = sum(got.values()), sum(lost.values())
print("packets %d (%.2f MB), bad sync %d, error-flagged (TEI) %d (%.2f%%), distinct PIDs %d" % (n, len(d)/1e6, bad, tei, 100*tei/max(1,n), len(pids)))
print("estimated lost packets: %d of %d (%.2f%%; continuity counters cannot see gaps of 16 or more)" % (tl, tg+tl, 100*tl/max(1, tg+tl)))
print("PIDs with most packets:", [(hex(k), v, "lost %d" % lost[k]) for k, v in got.most_common(6)])
