#!/bin/bash

set -e

# Help message
usage() {
  echo "Usage: $0 input.webm [output.gif] [--fast] [--scale WIDTH] [--fps N]"
  echo
  echo "  --fast           Speed up playback by 1.5x"
  echo "  --scale WIDTH    Scale output width (height auto-adjusts to keep aspect ratio)"
  echo "  --fps N          Set frames per second (default: 15)"
  exit 1
}

# --- Defaults ---
FAST_MODE=false
SCALE=1280
FPS=15

POSITIONAL=()

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      FAST_MODE=true
      shift
      ;;
    --scale)
      SCALE="$2"
      shift 2
      ;;
    --fps)
      FPS="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      POSITIONAL+=( "$1" )
      shift
      ;;
  esac
done

# Restore positional arguments
set -- "${POSITIONAL[@]}"

# --- Validate input ---
if [ -z "$1" ]; then
  usage
fi

INPUT="$1"
if [ ! -f "$INPUT" ]; then
  echo "Error: Input file '$INPUT' not found."
  exit 1
fi

BASENAME="${INPUT%.*}"
OUTPUT="${2:-$BASENAME.gif}"

# --- Speed filter ---
SPEED_FILTER=""
if [ "$FAST_MODE" = true ]; then
  SPEED_FILTER=",setpts=PTS/1.5"
  echo "⚡ Speed: 1.5x"
fi

echo "🎞️  Input: $INPUT"
echo "📁 Output: $OUTPUT"
echo "🎚️  FPS: $FPS"
echo "📐 Scale: ${SCALE}px wide"

PALETTE="/tmp/palette.png"

# --- Generate palette ---
ffmpeg -y -i "$INPUT" -vf "fps=$FPS,scale=${SCALE}:-1:flags=lanczos$SPEED_FILTER,palettegen" "$PALETTE"

# --- Generate GIF ---
ffmpeg -i "$INPUT" -i "$PALETTE" -filter_complex \
"fps=$FPS,scale=${SCALE}:-1:flags=lanczos$SPEED_FILTER[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" "$OUTPUT"

echo "✅ GIF created: $OUTPUT"
