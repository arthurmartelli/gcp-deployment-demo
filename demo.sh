#!/usr/bin/env bash

# Reusable Demo Framework =====================================================

# Configuration & Defaults ----------------------------------------------------
INTERACTIVE="${INTERACTIVE:-false}"
RECORD="${RECORD:-false}"
NO_ANIMATION="${NO_ANIMATION:-false}"
OUTPUT_FILE="${OUTPUT_FILE:-demos/demo.cast}"
WAIT="${WAIT:-1}"
DRY_RUN="${DRY_RUN:-false}"

# Help & Argument Parsing -----------------------------------------------------
demo_help() {
  local script_name="${1:-$0}"
  echo "Usage: $script_name [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -i, --interactive    Run in interactive mode for live demos"
  echo "  -r, --record         Record demo with asciinema"
  echo "  -n, --dry-run        Show commands without executing"
  echo "  -N, --no-animation   Disable typing animation (instant output)"
  echo "  -o, --output FILE    Output file for recording (default: $OUTPUT_FILE)"
  echo "  -h, --help           Show this help message"
}

demo_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -i | --interactive)  INTERACTIVE=true;  shift   ;;
      -r | --record)       RECORD=true;       shift   ;;
      -n | --dry-run)      DRY_RUN=true;      shift   ;;
      -N | --no-animation) NO_ANIMATION=true; shift  ;;
      -o | --output)       OUTPUT_FILE="$2";  shift 2 ;;
      -h | --help)         demo_help "$0";    exit 0  ;;
      *)
        echo "Unknown option: $1"
        echo "Use -h or --help for usage information"
        exit 1
        ;;
    esac
  done
}

# Core Demo Functions ---------------------------------------------------------

# Primitive: show a hint and block until the user presses a key.
# Always reads from /dev/tty so it works even when stdin is a pipe,
# a subshell, or an asciinema --command invocation.
#   $1  optional hint text shown after ↵ (default: "to continue")
demo_press_enter() {
  local hint="${1:-to continue}"
  printf ' \033[2m[↵ %s]\033[0m' "$hint"
  read -r -n 1 -s < /dev/tty
  echo  # move to the next line after the keypress
}

# Print text with a typewriter animation (or instantly in no-animation mode).
demo_type() {
  local text="$1"
  local delay="${2:-0.03}"

  if [[ "$NO_ANIMATION" == "true" ]]; then
    echo -e "$text"
  else
    for ((i = 0; i < ${#text}; i++)); do
      printf '%s' "${text:$i:1}"
      sleep "$delay"
    done
    sleep "$WAIT"
    echo
  fi
}

# Type a message, then pause.
# Interactive: wait for a keypress (shows "to continue" hint).
# Animated:    sleep for $WAIT seconds.
# No-animation: just print, no pause.
demo_wait() {
  local message="$1"
  demo_type "$message"

  if [[ "$INTERACTIVE" == "true" ]]; then
    demo_press_enter "to continue"
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    sleep "$WAIT"
  fi
}

# Type the command with a leading >, run it, then pause.
# Interactive: "to run" hint before execution, "to continue" hint after.
# Animated:    sleep before and after execution.
# No-animation: run immediately, no pauses.
#
# stderr is intentionally NOT suppressed — gcloud/kubectl/git write
# progress and error detail to stderr, and hiding it would confuse viewers.
demo_invoke() {
  local command="$*"
  demo_type "> $command"

  if [[ "$INTERACTIVE" == "true" ]]; then
    demo_press_enter "to run"
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    sleep "$WAIT"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $command"
  else
    eval "$command"
  fi

  if [[ "$INTERACTIVE" == "true" ]]; then
    demo_press_enter "to continue"
  elif [[ "$NO_ANIMATION" == "false" ]]; then
    sleep "$WAIT"
  fi
}

# Dummy placeholder — the sourcing script must override this.
demo_run() {
  echo "Please define a demo_run() function in your script to run the demo"
  exit 1
}

# Entry point: parse args, then either run or record.
demo_main() {
  demo_args "$@"

  if [[ "$RECORD" != "true" ]]; then
    demo_run
    return
  fi

  mkdir -p "$(dirname "$OUTPUT_FILE")"

  # Re-invoke this exact script (without --record) inside asciinema.
  # Asciinema allocates a PTY for its --command, so /dev/tty will be
  # available and the interactive prompts will work correctly.
  asciinema rec "$OUTPUT_FILE" \
    --overwrite \
    --command "INTERACTIVE=true $0"

  echo "To play back: asciinema play $OUTPUT_FILE"
}
