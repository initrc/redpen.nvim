#!/bin/sh

set -u

suite_count=0
test_count=0
for test_file in tests/test_*.lua; do
  if [ ! -f "$test_file" ]; then
    printf 'No tests found matching tests/test_*.lua\n'
    exit 1
  fi

  suite_count=$((suite_count + 1))
  printf 'Running suite %s\n' "$test_file"
  if suite_output=$(nvim --headless -u NONE -l "$test_file" 2>&1); then
    suite_test_count=$(printf '%s\n' "$suite_output" | sed -n 's/^REDPEN_TEST_COUNT=//p')
    case "$suite_test_count" in
      '' | *[!0-9]*)
        printf 'FAIL suite %s (invalid test count)\n' "$test_file"
        exit 1
        ;;
    esac
    test_count=$((test_count + suite_test_count))
    printf 'PASS suite %s (%d tests)\n' "$test_file" "$suite_test_count"
  else
    exit_code=$?
    if [ -n "$suite_output" ]; then printf '%s\n' "$suite_output"; fi
    printf 'FAIL suite %s (exit %d)\n' "$test_file" "$exit_code"
    exit "$exit_code"
  fi
done

printf 'All tests passed (%d tests across %d suites).\n' "$test_count" "$suite_count"
