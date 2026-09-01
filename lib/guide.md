# Engineering guide

Language-agnostic rules for every change made in this feature. Language specifics
are decided by the repository's own linters and formatters, not by this guide.

## Naming
- Intention-revealing names. No abbreviations, no single letters outside tight loops.
- Match the vocabulary already used in the surrounding code.

## Functions and modules
- Small, one responsibility, shallow nesting. Prefer early returns over nested branches.
- A function does what its name says and nothing else.

## Errors
- Fail fast. Never swallow an exception or ignore an error return.
- Error messages state what failed and what the caller can do about it.

## Tests
- Test behavior, not implementation. A refactor must not break a good test.
- One assertion focus per test; the test name states the behavior.
- Cover the failure path, not only the happy path.
- Write the test before the implementation, watch it fail, then make it pass.

## Structure
- Files that change together live together.
- Follow the repository's existing layout. Do not invent a new one.

## Comments
- Only for what the code cannot say: constraints, invariants, non-obvious reasons.
- Never narrate what the next line does.

## Formatting
- Whatever the repository's formatter or linter says wins.
- If there is none, match the existing files exactly.

## Scope
- Build exactly what the task asks. No speculative abstraction, options, or hooks.
- Reuse what already exists before writing anything new.
- Do not refactor untouched code.
