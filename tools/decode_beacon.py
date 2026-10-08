#!/usr/bin/env python3
"""
Read the live beacon (LiveBeacon.lua) back from a screenshot, as the Companion reads it.

    python3 tools/decode_beacon.py <screenshot.png>

Take the screenshot in game with the beacon on (/fg live on) and PNG screenshots
(/console screenshotFormat png; JPEG blurs the cells). Prints the frame: map, x, y, facing, class,
flags, the latest event, the recording id and the name channel's byte; compare it with /fg live. The contract is forever-codex's docs/LIVE-BEACON.md.
No dependencies: a small PNG reader (8-bit RGB or RGBA, any filter, not interlaced).
"""

import struct
import sys
import zlib

CELLS, CELL_PX, MAGIC, BYTES = 18, 3, 0xFC, 24


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG (set /console screenshotFormat png)")
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or color not in (2, 6) or interlace:
                sys.exit(f"{path}: only 8-bit RGB/RGBA, not interlaced")
            bpp = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw, stride, rows, prev = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp)
    for y in range(min(height, CELL_PX * 2)):              # only the top rows hold the strip
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return rows, bpp


def crc8(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 255 if crc & 0x80 else (crc << 1) & 255
    return crc


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rows, bpp = read_png(sys.argv[1])
    mid = CELL_PX // 2
    cells = [tuple(rows[mid][(i * CELL_PX + mid) * bpp:(i * CELL_PX + mid) * bpp + 3]) for i in range(CELLS)]
    black, white = cells[0], cells[-1]
    if any(w - b < 128 for w, b in zip(white, black)):
        sys.exit("no beacon: the top-left corner has no black and white calibration cells (/fg live on?)")
    nibbles = [min(15, max(0, int((v - black[ch]) * 255 / (white[ch] - black[ch]) // 16)))
               for cell in cells[1:-1] for ch, v in enumerate(cell)]
    b = [(nibbles[i * 2] << 4) | nibbles[i * 2 + 1] for i in range(BYTES)]
    ok = crc8(b[:BYTES - 1]) == b[BYTES - 1]
    if b[0] != MAGIC or not ok:
        sys.exit(f"not a beacon frame (magic {b[0]:#x}, checksum {'ok' if ok else 'broken'})")
    word = lambda i: (b[i] << 8) | b[i + 1]
    print(f"seq {word(1)}  map {word(3)}  x {word(5) / 655.35:.2f}  y {word(7) / 655.35:.2f}  "
          f"facing {b[9]}  class {b[10]}  flags {b[11]}")
    print(f"event #{b[12]} kind {b[13]} value {(b[14] << 16) | (b[15] << 8) | b[16]}  "
          f"recording {bytes(b[17:21]).hex()}  name [{b[21]}] = {b[22]}")


if __name__ == "__main__":
    main()
