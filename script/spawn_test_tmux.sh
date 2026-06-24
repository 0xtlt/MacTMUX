#!/usr/bin/env zsh
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./script/spawn_test_tmux.sh [prefix]

Spawns two tmux sessions:
  <prefix>-input-lab-<time>  interactive arrows/redraw test
  <prefix>-log-lab-<time>    large continuous logs for search/filter tests
EOF
}

timestamp() {
  date "+%H:%M:%S"
}

trim_recent_keys() {
  local value="$1"
  if (( ${#value} > 120 )); then
    print -r -- "${value[-120,-1]}"
  else
    print -r -- "$value"
  fi
}

run_input_lab() {
  emulate -L zsh

  local key rest_a rest_b sequence label recent_keys typed
  integer x=0
  integer y=0
  integer repaints=0
  typed=""
  recent_keys=""

  stty raw -echo
  trap 'stty sane; print -r -- ""; exit 0' INT TERM EXIT

  draw_input_lab() {
    integer row col
    local line
    print -n -- $'\e[2J\e[H'
    print -P -- "%F{cyan}MacTMUX interactive input lab%f"
    print -r -- "Arrows move the marker - type writes - Enter moves down - Backspace erases - q quits"
    print -r -- ""
    printf "position: x=%02d y=%02d  repaint=%d\n\n" "$x" "$y" "$repaints"

    for row in {0..11}; do
      line=""
      for col in {0..49}; do
        if (( row == y && col == x )); then
          line+="X"
        else
          line+="."
        fi
      done
      print -r -- "$line"
    done

    print -r -- ""
    print -r -- "typed: ${typed}"
    print -r -- "last keys:${recent_keys}"
  }

  while true; do
    draw_input_lab
    (( repaints += 1 ))
    IFS= read -rs -k 1 key || break
    label=""

    if [[ "$key" == $'\e' ]]; then
      IFS= read -rs -k 1 -t 0.02 rest_a || rest_a=""
      IFS= read -rs -k 1 -t 0.02 rest_b || rest_b=""
      sequence="${rest_a}${rest_b}"
      case "$sequence" in
        "[A")
          (( y = y > 0 ? y - 1 : y ))
          label="up"
          ;;
        "[B")
          (( y = y < 11 ? y + 1 : y ))
          label="down"
          ;;
        "[C")
          (( x = x < 49 ? x + 1 : x ))
          label="right"
          ;;
        "[D")
          (( x = x > 0 ? x - 1 : x ))
          label="left"
          ;;
        *)
          label="escape"
          ;;
      esac
    elif [[ "$key" == $'\r' || "$key" == $'\n' ]]; then
      (( y = y < 11 ? y + 1 : 0 ))
      label="enter"
    elif [[ "$key" == $'\177' || "$key" == $'\b' ]]; then
      if (( ${#typed} > 0 )); then
        typed="${typed[1,-2]}"
      fi
      label="backspace"
    elif [[ "$key" == "q" ]]; then
      break
    else
      typed+="$key"
      label="$key"
    fi

    if [[ -n "$label" ]]; then
      recent_keys="$(trim_recent_keys "${recent_keys} ${label}")"
    fi
  done
}

emit_log_line() {
  emulate -L zsh
  local i="$1"
  local time
  time="$(timestamp)"

  case $(( i % 6 )) in
    0)
      printf '\033[31m%s ERROR failed request status=502 route=/api/orders/%04d search-token=alpha http://localhost:3457/error/%04d\033[0m\n' "$time" "$i" "$i"
      ;;
    1)
      printf '\033[33m%s WARN deprecated API status=404 route=/api/products/%04d search-token=beta http://localhost:3457/warn/%04d\033[0m\n' "$time" "$i" "$i"
      ;;
    2)
      printf '\033[32m%s SUCCESS ready status=200 route=/collections/%04d search-token=gamma http://localhost:3457/success/%04d\033[0m\n' "$time" "$i" "$i"
      ;;
    3)
      printf '\033[34m%s INFO processing webhook topic=orders/create id=%04d search-token=delta\033[0m\n' "$time" "$i"
      ;;
    4)
      printf '\033[35m%s DEBUG trace cache_hit=true span=render-%04d search-token=epsilon\033[0m\n' "$time" "$i"
      ;;
    *)
      printf '%s plain heartbeat worker=preview index=%04d search-token=zeta\n' "$time" "$i"
      ;;
  esac
}

run_log_lab() {
  emulate -L zsh
  integer i=0

  print -P -- "%F{cyan}MacTMUX large log lab%f"
  print -r -- "Use search-token=alpha/gamma/zeta and log level filters to test the terminal surface."
  print -r -- ""

  while (( i < 1800 )); do
    emit_log_line "$i"
    (( i += 1 ))
  done

  while true; do
    emit_log_line "$i"
    (( i += 1 ))
    sleep 0.08
  done
}

if [[ "${1:-}" == "__input" ]]; then
  run_input_lab
  exit 0
fi

if [[ "${1:-}" == "__logs" ]]; then
  run_log_lab
  exit 0
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  print -u2 -- "tmux is required but was not found in PATH."
  exit 1
fi

prefix="${1:-mactmux}"
stamp="$(date +%H%M%S)"
script_path="${0:A}"
input_session="${prefix}-input-lab-${stamp}"
log_session="${prefix}-log-lab-${stamp}"

tmux new-session -d -s "$input_session" "zsh '$script_path' __input"
tmux new-session -d -s "$log_session" "zsh '$script_path' __logs"

cat <<EOF
Spawned tmux test sessions:
  $input_session
  $log_session

Refresh MacTMUX, then select the input lab for arrows or the log lab for search/filter testing.
EOF
