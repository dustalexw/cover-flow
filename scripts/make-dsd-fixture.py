#!/usr/bin/env python3
"""Writes Tests/CoverFlowTests/Fixtures/tone.dsf: 0.1 s of a 440 Hz stereo sine as DSD64.

No common tool encodes DSD, so the fixture is made with a second-order sigma-delta
modulator and written in the DSF layout (Sony's DSF specification 1.01)."""
import math
import struct
from pathlib import Path

RATE = 2_822_400          # DSD64
SECONDS = 0.1
BLOCK = 4096              # bytes per channel per block
CHANNELS = 2

def modulate(count):
    bits = []
    i1 = i2 = 0.0
    out = 0.0
    for n in range(count):
        x = 0.25 * math.sin(2 * math.pi * 440 * n / RATE)
        i1 += x - out
        i2 += i1 - out
        bit = 1 if i2 >= 0 else 0
        out = 1.0 if bit else -1.0
        bits.append(bit)
    return bits

def pack_lsb_first(bits):
    data = bytearray()
    for i in range(0, len(bits), 8):
        byte = 0
        for k, bit in enumerate(bits[i:i + 8]):
            byte |= bit << k
        data.append(byte)
    return data

samples = int(RATE * SECONDS)
channel = pack_lsb_first(modulate(samples))
blocks = math.ceil(len(channel) / BLOCK)
channel += bytes([0x69]) * (blocks * BLOCK - len(channel))   # DSD idle pattern
body = bytearray()
for b in range(blocks):
    for _ in range(CHANNELS):
        body += channel[b * BLOCK:(b + 1) * BLOCK]

fmt = struct.pack('<4sQIIIIIIQII', b'fmt ', 52, 1, 0, 2, CHANNELS, RATE, 1, samples, BLOCK, 0)
data = struct.pack('<4sQ', b'data', 12 + len(body)) + body
total = 28 + len(fmt) + len(data)
header = struct.pack('<4sQQQ', b'DSD ', 28, total, 0)
out = Path(__file__).resolve().parents[1] / 'Tests/CoverFlowTests/Fixtures/tone.dsf'
out.write_bytes(header + fmt + data)
print(f'{out}: {samples} samples per channel, {total} bytes')
