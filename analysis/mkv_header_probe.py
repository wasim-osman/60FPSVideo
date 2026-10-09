#!/usr/bin/env python3
"""Dump the Matroska header fields that move a stream's start time.

`ffprobe` reports a stream's `start_time` but not *why* it is that value. Three
Matroska elements can move it, and they are indistinguishable from the outside:

  CodecDelay         0x56AA   samples of priming the decoder must discard
  SeekPreRoll        0x56BB   samples a player must decode before a seek target
  TrackTimestampScale 0x23314F a per-track multiplier (deprecated)

CodecDelay is the interesting one: a muxer that writes it is *stating* a decoder
delay, and a demuxer that honours it adds it back to every timestamp. That makes a
stream's `start_time` look late while the decoded content is exactly where it was --
which is precisely the question this project had to answer about DTS-HD MA.

Usage: mkv_header_probe.py FILE [FILE...]
"""
from __future__ import annotations

import sys

# EBML IDs we care about, and how to read their payload.
MASTER = 0x80          # bit pattern for a master element
ELEMENTS = {
    0x18538067: "Segment",
    0x1549A966: "Info",
    0x1654AE6B: "Tracks",
    0xAE: "TrackEntry",
    0x1F43B675: "Cluster",
    0x2AD7B1: "TimestampScale",
    0x56AA: "CodecDelay",
    0x56BB: "SeekPreRoll",
    0x23314F: "TrackTimestampScale",
    0xD7: "TrackNumber",
    0x86: "CodecID",
    0x83: "TrackType",
    0x9C: "FlagDefault",
    0x1F43B675: "Cluster",
}
# Elements whose payload we print as a number.
NUMERIC = {0x2AD7B1, 0x56AA, 0x56BB, 0x23314F, 0xD7, 0x83, 0x9C}
# Elements whose payload is text.
TEXT = {0x86}
# Masters to descend into; anything else is skipped by length.
DESCEND = {0x18538067, 0x1549A966, 0x1654AE6B, 0xAE}


def read_id(buf: bytes, pos: int) -> tuple[int, int]:
    first = buf[pos]
    length = 1
    mask = 0x80
    while not (first & mask):
        mask >>= 1
        length += 1
        if length > 4:
            raise ValueError(f"bad element id at {pos}")
    value = int.from_bytes(buf[pos:pos + length], "big")
    return value, length


def read_size(buf: bytes, pos: int) -> tuple[int, int]:
    first = buf[pos]
    length = 1
    mask = 0x80
    while not (first & mask):
        mask >>= 1
        length += 1
        if length > 8:
            raise ValueError(f"bad size at {pos}")
    value = int.from_bytes(buf[pos:pos + length], "big")
    value &= (1 << (7 * length)) - 1     # strip the length marker
    return value, length


def walk(buf: bytes, start: int, end: int, depth: int, out: list) -> None:
    pos = start
    while pos < end:
        try:
            eid, idlen = read_id(buf, pos)
            size, sizelen = read_size(buf, pos + idlen)
        except (ValueError, IndexError):
            return
        body = pos + idlen + sizelen
        unknown = size == (1 << (7 * sizelen)) - 1
        if unknown:
            return
        name = ELEMENTS.get(eid)
        if eid in NUMERIC:
            raw = buf[body:body + size]
            value = int.from_bytes(raw, "big") if raw else 0
            out.append((depth, name, value))
        elif eid in TEXT:
            out.append((depth, name, buf[body:body + size].decode("ascii", "replace")))
        elif eid in DESCEND and depth < 3:
            out.append((depth, name, ""))
            walk(buf, body, min(body + size, end), depth + 1, out)
        pos = body + size
        # A cluster is where the interesting header ends.
        if eid == 0x1F43B675:
            return


def main() -> int:
    for path in sys.argv[1:]:
        with open(path, "rb") as handle:
            buf = handle.read(1 << 20)      # the header is always in the first MB
        out: list = []
        walk(buf, 0, len(buf), 0, out)
        print(f"=== {path}")
        for depth, name, value in out:
            if name is None:
                continue
            pad = "  " * depth
            if isinstance(value, int) and name in ("CodecDelay", "SeekPreRoll"):
                print(f"{pad}{name:<20} {value:>8}  ({value / 48000 * 1000:.3f} ms at 48 kHz)")
            else:
                print(f"{pad}{name:<20} {value}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
