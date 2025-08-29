#!/usr/bin/env python3
"""Extract resource objects from FHIR-like Bundle JSON (file or stdin) into NDJSON.

Usage:
  extract_resources.py --input localfile.json --output resources.ndjson
  cat bundle.ndjson | extract_resources.py --output resources.ndjson

The script expects either a single JSON Bundle object (with entry[]),
or NDJSON where each line is either a Bundle or a Resource. It writes
one resource JSON per line to the output file.
"""
from __future__ import annotations
import argparse
import json
import sys
from typing import Any, IO


def process_bundle_obj(obj: Any, out_f: IO[str]) -> int:
    if not isinstance(obj, dict):
        return 0
    entries = obj.get("entry")
    if not isinstance(entries, list):
        return 0
    count = 0
    for e in entries:
        if not isinstance(e, dict):
            continue
        r = e.get("resource")
        if r is None:
            continue
        out_f.write(json.dumps(r, ensure_ascii=False) + "\n")
        count += 1
    return count


def process_resource_obj(obj: Any, out_f: IO[str]) -> int:
    # obj is already a resource (has resourceType or id)
    if not isinstance(obj, dict):
        return 0
    if 'resourceType' in obj or 'id' in obj:
        out_f.write(json.dumps(obj, ensure_ascii=False) + "\n")
        return 1
    return 0


def extract_from_file(input_path: str, out_path: str) -> int:
    total = 0
    with open(input_path, 'r', encoding='utf-8') as inf, open(out_path, 'w', encoding='utf-8') as outf:
        # Try reading whole file as JSON bundle first
        try:
            inf.seek(0)
            obj = json.load(inf)
            n = process_bundle_obj(obj, outf)
            if n > 0:
                return n
        except Exception:
            inf.seek(0)
        # Fall back to line-by-line NDJSON processing
        for line in inf:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                # ignore invalid lines
                continue
            total += process_bundle_obj(obj, outf)
            total += process_resource_obj(obj, outf)
    return total


def extract_from_stdin(out_path: str) -> int:
    total = 0
    with open(out_path, 'w', encoding='utf-8') as outf:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            total += process_bundle_obj(obj, outf)
            total += process_resource_obj(obj, outf)
    return total


def main() -> None:
    p = argparse.ArgumentParser(description='Extract resources from bundle JSON/NDJSON')
    p.add_argument('--input', '-i', help='Input file path (optional). If omitted, reads stdin')
    p.add_argument('--output', '-o', required=True, help='Output NDJSON file (one resource per line)')
    args = p.parse_args()

    if args.input:
        n = extract_from_file(args.input, args.output)
    else:
        n = extract_from_stdin(args.output)

    print(f'Wrote {n} resource lines to {args.output}')


if __name__ == '__main__':
    main()
