#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Receive AD9226 UDP blocks; optionally export raw codes and flags to CSV."""
import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
import socket
import struct


@dataclass
class Block:
    udp_sequence: int
    block_sequence: int
    first_index: int
    decimation: int
    samples: tuple


def decode_payload(payload):
    if len(payload) < 18:
        raise ValueError("Payload is shorter than the acquisition header")
    udp_seq, magic, block_seq, first_index, decimation, sample_count = struct.unpack_from("!H4sIIHH", payload)
    if magic != b"AD26":
        raise ValueError("Wrong acquisition magic (expected AD26)")
    if decimation < 8 or sample_count < 2 or sample_count > 720 or sample_count % 2:
        raise ValueError("Unsupported acquisition parameters in packet")
    if len(payload) != 18 + sample_count * 2:
        raise ValueError(f"Payload size {len(payload)} does not match {sample_count} samples")
    samples = struct.unpack_from(f"!{sample_count}H", payload, 18)
    if any(x & 0xc000 for x in samples):
        raise ValueError("Reserved sample bits are nonzero")
    return Block(udp_seq, block_seq, first_index, decimation, samples)


def sample_value(word, data_format):
    code = word & 0xfff
    if data_format == "twos-complement":
        return code - 4096 if code & 0x800 else code
    if data_format == "offset-binary":
        return code - 2048
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--packets", type=int, default=0, help="Stop after N accepted blocks; 0 means continuous")
    parser.add_argument("--output", type=Path, help="Write per-sample CSV (may limit sustained throughput)")
    parser.add_argument("--format", choices=["raw", "twos-complement", "offset-binary"], default="raw")
    args = parser.parse_args()
    previous = None
    count = total_samples = missing = 0
    output = args.output.open("w", newline="", encoding="utf-8") if args.output else None
    writer = csv.writer(output) if output else None
    if writer:
        writer.writerow(["block", "sample_index", "code", "value", "otr", "test_pattern"])
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
            sock.bind((args.bind, args.port))
            print(f"Listening on {args.bind}:{args.port}; Ctrl+C stops", flush=True)
            while not args.packets or count < args.packets:
                payload, peer = sock.recvfrom(65535)
                try:
                    block = decode_payload(payload)
                except ValueError as error:
                    print(f"Rejected datagram from {peer}: {error}", flush=True)
                    continue
                if previous is not None:
                    gap = (block.block_sequence - previous - 1) & 0xffffffff
                    if gap < 0x80000000:
                        missing += gap
                    else:
                        print("Sequence restarted or datagram arrived out of order", flush=True)
                previous = block.block_sequence
                count += 1
                total_samples += len(block.samples)
                if writer:
                    for i, word in enumerate(block.samples):
                        index = (block.first_index + i * block.decimation) & 0xffffffff
                        writer.writerow([block.block_sequence, index, word & 0xfff,
                                         sample_value(word, args.format), (word >> 12) & 1, (word >> 13) & 1])
                if count == 1 or count % 1000 == 0:
                    print(f"blocks={count} samples={total_samples} missing_blocks={missing} "
                          f"last={block.block_sequence} decimation={block.decimation}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        if output:
            output.close()
        print(f"Received {count} blocks, {total_samples} samples; missing blocks={missing}")


if __name__ == "__main__":
    main()
