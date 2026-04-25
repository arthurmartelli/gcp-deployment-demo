#!/usr/bin/env bash

# Reusable Demo Framework =====================================================

# Configuration & Defaults -----------------------------------------------------
INTERACTIVE="${INTERACTIVE:-false}"
RECORD="${RECORD:-false}"
NO_ANIMATION="${NO_ANIMATION:-false}"
OUTPUT_FILE="${OUTPUT_FILE:-demos/demo.cast}"
WAIT="${WAIT:-1}"

# Help & Argument Parsing ------------------------------------------------------
demo_help() {
  local script_name="${1:-$0}"
  echo "Usage: $script_name [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -i, --interactive    Run in interactive mode for live demos"
  echo "  -r, --record         Record demo with asciinema"
  echo "  -n, --no-animation   Disable typing animation (instant output)"
  echo "  -o, --output FILE    Output file for recording (default: $OUTPUT_FILE)"
  echo "  -h, --help           Show this help message"
}

demo_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -i | --interactive)
      INTERACTIVE=true
      shift
      ;;
    -r | --record)
      RECORD=true
      shift
      ;;
    -n | --no-animation)
      NO_ANIMATION=true
      shift
      ;;
    -o | --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h | --help)
      demo_help "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information"
      exit 1
      ;;
    esac
  done
}

# Core Demo Functions ---------------------------------------------------------

# Function to simulate typing with delays (respects no-animation flag)
demo_type() {
  local text="$1"
  local delay="${2:-0.03}"

  if [[ "$NO_ANIMATION" == "true" ]]; then
    # No animation - just print the text immediately
    echo "$text"
  else
    # Animated typing
    for ((i = 0; i < ${#text}; i++)); do
      printf '%s' "${text:$i:1}"
      sleep "$delay"
    done

    sleep "$WAIT"
    echo
  fi
}

# Wait function - always types, but interactive mode waits for key
demo_wait() {
  local message="$1"
  demo_type "$message"

  if [[ "$INTERACTIVE" == "true" ]]; then
    read -r -n 1 -s
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    # Skip sleep in no-animation mode
    sleep "$WAIT"
  fi
}

# Invoke function - always types command, interactive mode has extra waits
demo_invoke() {
  local command="$*"
  demo_type "> $command"

  if [[ "$INTERACTIVE" == "true" ]]; then
    read -r -n 1 -s
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    sleep "$WAIT"
  fi

  eval "$command" 2>/dev/null

  if [[ "$INTERACTIVE" == "true" ]]; then
    read -r -n 1 -s
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    sleep "$WAIT"
  fi
}

# Dummy run_demo function to prompt user definition
demo_run() {
  echo "Please define a demo_run() function in your script to run the demo"
  exit 1
}

# Run the demo framework, which calls the user-defined demo_run function
demo_main() {
  demo_args "$@"

  if [[ "$RECORD" != "true" ]]; then
    demo_run
    exit
  fi

  # Ensure output directory exists
  mkdir -p "$(dirname "$OUTPUT_FILE")"

  # Record the demo
  asciinema rec "$OUTPUT_FILE" \
    --overwrite \
    --command "$0"

  echo "To play back: asciinema play $OUTPUT_FILE"
}
