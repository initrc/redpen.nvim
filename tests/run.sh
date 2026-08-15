#!/bin/sh

set -u

test_count=0
for test_file in tests/test_*.lua; do
  if [ ! -f "$test_file" ]; then
    printf 'No tests found matching tests/test_*.lua\n'
    exit 1
  fi

  test_count=$((test_count + 1))
  printf 'Running %s\n' "$test_file"
  if nvim --headless -u NONE -l "$test_file"; then
    printf 'PASS %s\n' "$test_file"
  else
    exit_code=$?
    printf 'FAIL %s (exit %d)\n' "$test_file" "$exit_code"
    exit "$exit_code"
  fi
done

printf 'All tests passed (%d total).\n' "$test_count"
