#!/usr/bin/env bash
set -euo pipefail

payload="$(cat)"

# Extract the terminal command from the hook payload without external dependencies.
extract_command() {
  local cmd
  cmd="$(printf '%s' "$payload" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  printf '%s' "$cmd"
}

command_text="$(extract_command)"

# If no command was found, require explicit approval.
if [[ -z "$command_text" ]]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"No command found in hook payload"}}'
  exit 0
fi

# Block obviously destructive operations by default.
if [[ "$command_text" =~ (^|[[:space:]])(rm[[:space:]]+-rf|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+checkout[[:space:]]+--) ]]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked destructive command"}}'
  exit 0
fi

# Auto-approve safe read-only and dry-run style commands, including the common
# 'cd <path> && <command>' prefix used in this repo.
if [[ "$command_text" =~ ^((cd[[:space:]]+[^;&|]+[[:space:]]*&&[[:space:]]+)?(ls|pwd|cat|sed|awk|head|tail|wc|rg|grep|find|which|command[[:space:]]+-v|echo|git[[:space:]]+status|git[[:space:]]+diff|git[[:space:]]+log|helm[[:space:]]+template|helm[[:space:]]+lint|helm[[:space:]]+version|argocd|kubectl|cilium))([[:space:]].*)?$ ]]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Safe command matched allowlist"}}'
  exit 0
fi

# Ask for confirmation for everything else.
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Command not in auto-allow list"}}'
