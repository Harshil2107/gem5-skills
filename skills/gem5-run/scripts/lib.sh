# Shared helpers for the gem5-run scripts. Source this file.

_config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}
# shellcheck source=/dev/null
[ -f "$_config" ] && source "$_config"

# The task folder: the nearest folder at or above $PWD that has a notes.md.
task_dir() {
    local d=$PWD
    while [ "$d" != / ]; do
        [ -f "$d/notes.md" ] && { echo "$d"; return 0; }
        d=$(dirname "$d")
    done
    return 1
}

# gem5 to use: gem5/ in the task folder, else GEM5_CLONE from the settings.
default_gem5() {
    local t
    if t=$(task_dir) && [ -d "$t/gem5" ]; then
        echo "$t/gem5"
    elif [ -n "${GEM5_CLONE:-}" ]; then
        echo "$GEM5_CLONE"
    else
        return 1
    fi
}

# Where run and build output goes: the task folder's runs/, else <gem5>/m5out.
runs_dir() {
    local gem5="$1" t
    if t=$(task_dir); then
        echo "$t/runs"
    elif [ -f "$gem5/../notes.md" ]; then
        realpath "$gem5/../runs"
    else
        echo "$gem5/m5out"
    fi
}

# The guest console file of a run, if there is one.
console_file() {
    local f
    for f in board.pc.com_1.device board.platform.terminal board.terminal \
             system.pc.com_1.device system.terminal; do
        [ -f "$1/$f" ] && { echo "$1/$f"; return 0; }
    done
    return 1
}

# The run's pid if it is still running (checks the pid really is this run).
run_pid() {
    local d="$1" pid
    pid=$(cat "$d/pid" 2>/dev/null) || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -o args= -p "$pid" 2>/dev/null | grep -qF -- "$d" || return 1
    echo "$pid"
}

fmt_secs() {
    local s=$1
    if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}
