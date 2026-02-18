#!/bin/zsh
set -euo pipefail

mode="attach"
attach_pid=""
launch_binary=""
output="/tmp/ControlPower.trace"
time_limit="30s"
device=""

usage() {
  cat <<USAGE
Usage:
  $0 --attach <pid> [--output <trace>] [--time-limit <duration>] [--device <name-or-udid>]
  $0 --launch <binary-path> [--output <trace>] [--time-limit <duration>] [--device <name-or-udid>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --attach)
      mode="attach"
      attach_pid="$2"
      shift 2
      ;;
    --launch)
      mode="launch"
      launch_binary="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --time-limit)
      time_limit="$2"
      shift 2
      ;;
    --device)
      device="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

rm -rf "$output"

common=(record --instrument 'CPU Profiler' --time-limit "$time_limit" --output "$output")
if [[ -n "$device" ]]; then
  common+=(--device "$device")
fi

if [[ "$mode" == "attach" ]]; then
  if [[ -z "$attach_pid" ]]; then
    echo "Missing --attach <pid>"
    usage
    exit 1
  fi
  xcrun xctrace "${common[@]}" --attach "$attach_pid"
else
  if [[ -z "$launch_binary" ]]; then
    echo "Missing --launch <binary-path>"
    usage
    exit 1
  fi
  if [[ ! -x "$launch_binary" ]]; then
    echo "Launch binary is not executable: $launch_binary"
    exit 1
  fi
  xcrun xctrace "${common[@]}" --launch -- "$launch_binary"
fi

echo "Trace saved to: $output"
