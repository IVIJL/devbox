#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract data from JSON
session_id=$(echo "$input" | jq -r '.session_id // ""')
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // "~"')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // ""')

# Get folder name (project name or current directory basename)
if [ -n "$project_dir" ] && [ "$project_dir" != "null" ]; then
    folder_name=$(basename "$project_dir")
else
    folder_name=$(basename "$current_dir")
fi

# Calculate session duration
session_start_file="/tmp/claude_session_${session_id}_start"
current_time=$(date +%s)

if [ ! -f "$session_start_file" ]; then
    echo "$current_time" > "$session_start_file"
    session_duration="0m"
else
    start_time=$(cat "$session_start_file")
    duration_seconds=$((current_time - start_time))

    if [ $duration_seconds -lt 60 ]; then
        session_duration="${duration_seconds}s"
    elif [ $duration_seconds -lt 3600 ]; then
        minutes=$((duration_seconds / 60))
        session_duration="${minutes}m"
    else
        hours=$((duration_seconds / 3600))
        minutes=$(((duration_seconds % 3600) / 60))
        session_duration="${hours}h${minutes}m"
    fi
fi

# Get git branch (suppress error messages)
git_branch=""
if [ -d "$current_dir/.git" ] || git -C "$current_dir" rev-parse --git-dir >/dev/null 2>&1; then
    git_branch=$(git -C "$current_dir" branch --show-current 2>/dev/null || echo "")
    if [ -n "$git_branch" ]; then
        git_branch=" [git:$git_branch]"
    fi
fi

# Format the status line with colors
printf "\033[36m%s\033[0m \033[33m%s\033[0m\033[32m%s\033[0m \033[35m⏱ %s\033[0m" \
    "$model_name" \
    "$folder_name" \
    "$git_branch" \
    "$session_duration"
