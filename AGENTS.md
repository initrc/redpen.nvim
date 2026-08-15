# AGENTS.md

## Problem Solving

1. Clarify the request before implementation. State assumptions that affect the
   result, surface meaningful tradeoffs, and limit the scope to what the request
   needs. If ambiguity would change the result, ask before coding.
2. Define a verifiable outcome before implementation. For multi-step work, give
   a brief plan and run the relevant checks before finishing.

## Implementation

3. Apply object-oriented programming (OOP) principles when modeling domain code.
   Start with the smallest domain model, put behavior on the domain object it
   naturally belongs to, and encapsulate internal data and logic.
4. Keep production contracts strict. Do not make required dependencies nullable
   or optional for tests; inject collaborators so tests can provide substitutes
   without weakening production types.
5. Prefer straightforward code. Avoid premature abstractions and handling
   impossible cases.
6. Limit edits to what the implementation requires. Match the surrounding
   style, avoid unrelated cleanup, and remove only unused code created by your
   change.

## Readability and Structure

7. Use clear, consistent domain language and descriptive names. Use named
   constants for important values. Keep comments brief and explain why, not what
   the code already says.
8. Organize source files into folders by responsibility.

## Testing

Name executable test files `tests/test_*.lua`. Run the test suite from the
repository root:

```sh
./tests/run.sh
```
