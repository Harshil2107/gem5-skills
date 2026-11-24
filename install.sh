#!/bin/bash
# Install the gem5 skills for Claude Code: link each skill in skills/ into
# ~/.claude/skills/ (so `git pull` here updates them), and create the
# settings file from the template if you don't have one yet.
# Usage: ./install.sh

set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.claude/skills"
config=${GEM5_SKILLS_CONFIG:-$HOME/.config/gem5-skills/config}

mkdir -p "$dest"
for skill in "$repo"/skills/*/; do
    skill=${skill%/}
    name=$(basename "$skill")
    target="$dest/$name"
    if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$skill")" ]; then
        echo "ok       $name (already linked)"
    elif [ -e "$target" ] || [ -L "$target" ]; then
        echo "skipped  $name: $target already exists. Move it away and rerun."
    else
        ln -s "$skill" "$target"
        echo "linked   $name -> $skill"
    fi
done

if [ -f "$config" ]; then
    echo "ok       settings file $config"
else
    mkdir -p "$(dirname "$config")"
    cp "$repo/skills/gem5-branch/config.example" "$config"
    echo "created  $config"
    echo "         Edit it: set GITHUB_USER, GEM5_CLONE, RESOURCES_CLONE and WORK_DIR."
fi
