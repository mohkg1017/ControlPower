#!/usr/bin/env python3
import argparse
import subprocess
import sys


def run_command(cmd: list[str]) -> None:
    completed = subprocess.run(cmd, capture_output=True, text=True)
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr)
        raise SystemExit(completed.returncode)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--run", default="1")
    args = parser.parse_args()

    xpath = f'/trace-toc/run[@number="{args.run}"]/data/table[@schema="time-sample"]'
    run_command([
        "xcrun",
        "xctrace",
        "export",
        "--input",
        args.trace,
        "--xpath",
        xpath,
        "--output",
        args.output,
    ])


if __name__ == "__main__":
    main()
