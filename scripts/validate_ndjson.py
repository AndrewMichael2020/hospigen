#!/usr/bin/env python3
"""Small NDJSON validator.

Usage:
  python3 scripts/validate_ndjson.py /path/to/file.ndjson [--max-err 5]

Prints parsing errors (first N) and exits with non-zero if any found.
"""
import sys
import json
from pathlib import Path


def validate(path: Path, max_err: int = 5):
    bad = []
    total = 0
    with path.open('rb') as f:
        for i, raw in enumerate(f, 1):
            s = raw.rstrip(b"\n\r")
            if not s.strip():
                continue
            total += 1
            try:
                # decode strictly to surface invalid encoding
                text = s.decode('utf-8')
                json.loads(text)
            except Exception as e:
                bad.append((i, str(e), s[:200]))
                if len(bad) >= max_err:
                    break
    return total, bad


def main():
    if len(sys.argv) < 2:
        print('usage: validate_ndjson.py file.ndjson [--max-err N]')
        raise SystemExit(2)
    p = Path(sys.argv[1])
    max_err = 5
    if len(sys.argv) >= 3 and sys.argv[2].startswith('--max-err'):
        try:
            max_err = int(sys.argv[2].split('=')[-1])
        except Exception:
            pass
    total, bad = validate(p, max_err=max_err)
    print(f'Lines checked (non-empty): {total}')
    if not bad:
        print('All lines parse as JSON (UTF-8).')
        raise SystemExit(0)
    print('Parsing errors (first %d):' % len(bad))
    for ln, err, sample in bad:
        print(f'  Line {ln}: {err}')
        print('    sample bytes:', sample)
    raise SystemExit(1)


if __name__ == '__main__':
    main()
