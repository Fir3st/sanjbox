#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher: Bash). Denies any `git commit` whose command text
# carries an attribution trailer. Reads the hook JSON from stdin.
input=$(cat)

echo "$input" | grep -qiE 'git[[:space:]]+([^;&|]*[[:space:]])?commit([^[:alnum:]_-]|$)' || exit 0

if echo "$input" | grep -qiE 'co-authored-by|generated with[^"]{0,20}claude|claude\.com/claude-code'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Commit blocked: attribution lines (Co-Authored-By, Generated with Claude Code) are forbidden in this repo. Remove them and commit again."}}'
fi
exit 0
