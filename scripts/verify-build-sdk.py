#!/usr/bin/env python3
"""Read linker metadata; never rewrite an executable's compatibility flags."""
import argparse
import re
import subprocess


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def verify(output, expected_sdk, minimum="14.0"):
    sdks = re.findall(r"^\s*sdk\s+(\d+(?:\.\d+)*)\s*$", output, re.MULTILINE)
    minimums = re.findall(r"^\s*minos\s+(\d+(?:\.\d+)*)\s*$", output, re.MULTILINE)
    if not sdks or not minimums or len(sdks) != len(minimums):
        raise ValueError("Missing build SDK or minimum macOS metadata")
    if any(version(value) != version(expected_sdk) for value in sdks):
        raise ValueError(f"Recorded SDK {sdks} does not match selected SDK {expected_sdk}")
    if any(version(value) != version(minimum) for value in minimums):
        raise ValueError(f"Minimum macOS changed: {minimums}; expected {minimum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("executables", nargs="+")
    args = parser.parse_args()
    for executable in args.executables:
        result = subprocess.run(["xcrun", "vtool", "-show-build", executable],
                                check=True, capture_output=True, text=True)
        verify(result.stdout, args.sdk)
        print(f"Verified SDK {args.sdk}, minimum macOS 14.0: {executable}")


if __name__ == "__main__":
    main()
