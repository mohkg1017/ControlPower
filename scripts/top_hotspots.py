#!/usr/bin/env python3
import argparse
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter


def symbolicate(binary: str, load_address: str, address: str) -> str:
    command = [
        "atos",
        "-o",
        binary,
        "-l",
        load_address,
        address,
    ]
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        return address
    output = completed.stdout.strip()
    return output or address


def extract_addresses(path: str) -> list[str]:
    root = ET.parse(path).getroot()
    addresses: list[str] = []
    for node in root.findall(".//text-address"):
        raw = (node.text or "").strip()
        if not raw:
            continue
        if raw.startswith("0x"):
            addresses.append(raw)
            continue
        try:
            addresses.append(hex(int(raw)))
        except ValueError:
            continue
    return addresses


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--load-address", required=True)
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()

    addresses = extract_addresses(args.samples)
    if not addresses:
        print("No sampled addresses found in input XML.")
        return

    counts = Counter(addresses)
    print(f"Top {min(args.top, len(counts))} hotspots")
    for address, count in counts.most_common(args.top):
        symbol = symbolicate(args.binary, args.load_address, address)
        print(f"{count:>6}  {address}  {symbol}")


if __name__ == "__main__":
    main()
