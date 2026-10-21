#!/usr/bin/env bash
# readaloud: Fast, lightweight text-to-speech CLI using Piper and en-GB voice
#
# Usage:
#   readaloud "Hello world"
#   echo "Hello world" | readaloud
#   readaloud -s 1.2 "Faster speech"
#   readaloud -m /path/to/model.onnx "Custom model"
#   readaloud -o output.wav "Save audio to file"

set -eo pipefail

PIPER_BIN="${PIPER_BIN:-/usr/sbin/piper-tts}"
DEFAULT_MODEL="/home/engon/models/piper/en_GB-alan-medium.onnx"
MODEL="${READALOUD_MODEL:-$DEFAULT_MODEL}"
SPEAKER="${READALOUD_SPEAKER:-0}"
SPEED="${READALOUD_SPEED:-1.0}"
OUTPUT_FILE=""
QUIET=1
RAW_MODE=0

usage() {
    cat <<EOF
Usage: readaloud [options] [text ...]
       echo "text" | readaloud [options]

Options:
  -m, --model <path>     Path to Piper ONNX model (default: en_GB-alan-medium)
  -s, --speed <float>    Speed multiplier, e.g. 1.1 or 0.9 (default: 1.0)
  -p, --speaker <int>    Speaker ID for multi-speaker models (default: 0)
  -o, --output <file>    Save WAV to file instead of playing directly
  --no-clean             Do not clean up markdown symbols before speech
  -v, --verbose          Show Piper synthesis logs
  -h, --help             Show this help message
EOF
}

# Parse options
CLEAN_TEXT=1
TEXT_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)
            MODEL="$2"; shift 2 ;;
        -s|--speed)
            SPEED="$2"; shift 2 ;;
        -p|--speaker)
            SPEAKER="$2"; shift 2 ;;
        -o|--output)
            OUTPUT_FILE="$2"; shift 2 ;;
        --no-clean)
            CLEAN_TEXT=0; shift ;;
        -v|--verbose)
            QUIET=0; shift ;;
        -h|--help)
            usage; exit 0 ;;
        --)
            shift
            TEXT_ARGS+=("$@")
            break
            ;;
        *)
            TEXT_ARGS+=("$1"); shift ;;
    esac
done

# Collect text from args or stdin
TEXT="${TEXT_ARGS[*]:-}"
if [[ -z "$TEXT" ]]; then
    if [[ ! -t 0 ]]; then
        TEXT="$(cat)"
    fi
fi

if [[ -z "$TEXT" ]]; then
    usage >&2
    exit 1
fi

if [[ ! -x "$PIPER_BIN" ]]; then
    echo "Error: piper-tts binary not found at $PIPER_BIN" >&2
    exit 1
fi

if [[ ! -f "$MODEL" ]]; then
    echo "Error: voice model not found at $MODEL" >&2
    exit 1
fi

# Detect sample rate from model json config
CONFIG_FILE="${MODEL}.json"
SAMPLE_RATE="22050"
if [[ -f "$CONFIG_FILE" ]]; then
    sr=$(grep -o '"sample_rate":[[:space:]]*[0-9]*' "$CONFIG_FILE" | grep -o '[0-9]*' | head -n 1)
    if [[ -n "$sr" ]]; then
        SAMPLE_RATE="$sr"
    fi
fi

# Clean markdown formatting so Piper speaks naturally instead of saying "asterisk asterisk"
if [[ "$CLEAN_TEXT" -eq 1 ]]; then
    TEXT="$(printf "%s\n" "$TEXT" | sed -E \
        -e 's/```[^`]*```//g' \
        -e 's/`([^`]+)`/\1/g' \
        -e 's/\[([^]]+)\]\([^)]+\)/\1/g' \
        -e 's/^#{1,6}[[:space:]]*//' \
        -e 's/^[[:space:]]*[\*\+-][[:space:]]+/ /' \
        -e 's/\*\*([^\*]+)\*\*/\1/g' \
        -e 's/\*([^\*]+)\*/\1/g' \
        -e 's/__([^_]+)__/\1/g' \
        -e 's/_([^_]+)_/\1/g' \
        -e 's/~~([^~]+)~~/\1/g' \
        -e 's/https?:\/\/[^[:space:]]+/link/g')"
fi

# Calculate length_scale from speed multiplier: length_scale = 1 / speed
LENGTH_SCALE="$(awk -v spd="$SPEED" 'BEGIN { if (spd <= 0) spd = 1.0; printf "%.3f", 1.0 / spd }')"

PIPER_FLAGS=(-m "$MODEL" --speaker "$SPEAKER" --length_scale "$LENGTH_SCALE")
if [[ "$QUIET" -eq 1 ]]; then
    PIPER_FLAGS+=(-q)
fi

# If output file requested, synthesize directly to WAV
if [[ -n "$OUTPUT_FILE" ]]; then
    PIPER_FLAGS+=(-f "$OUTPUT_FILE")
    printf "%s\n" "$TEXT" | "$PIPER_BIN" "${PIPER_FLAGS[@]}"
    exit 0
fi

# Playback: Use raw streaming to paplay so multi-line text plays continuously
# without terminating after the first line's WAV header.
if command -v paplay >/dev/null 2>&1; then
    printf "%s\n" "$TEXT" | "$PIPER_BIN" "${PIPER_FLAGS[@]}" --output_raw | \
        paplay --raw --rate="$SAMPLE_RATE" --channels=1 --format=s16le
elif command -v pw-play >/dev/null 2>&1; then
    # pw-play requires a container header from stdin; generate full wav via temp file
    TMP_WAV="$(mktemp /tmp/readaloud-XXXXXX.wav)"
    trap 'rm -f "$TMP_WAV"' EXIT
    printf "%s\n" "$TEXT" | "$PIPER_BIN" "${PIPER_FLAGS[@]}" -f "$TMP_WAV"
    pw-play "$TMP_WAV"
elif command -v ffplay >/dev/null 2>&1; then
    printf "%s\n" "$TEXT" | "$PIPER_BIN" "${PIPER_FLAGS[@]}" --output_raw | \
        ffplay -nodisp -autoexit -loglevel error -f s16le -ar "$SAMPLE_RATE" -ch_layout mono -i -
else
    echo "Error: no audio player found (paplay, pw-play, ffplay)" >&2
    exit 1
fi
