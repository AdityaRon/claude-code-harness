---
paths:
  - "**/*.py"
  - "**/pytest.ini"
---

# Reading a test run

- pytest: ANSI colour breaks a `^FAILED` grep, `-q` truncates the traceback, and
  piping makes the shell's exit code the last command's rather than pytest's.
  Assert on the summary line, not on a grep of the stream.
- A red run gets ONE named cause from whoever triages it first. Group the
  failures by error type before naming it; "one cause" is usually true of the
  first three and false of the rest.
- A test that cannot fail is worse than no test. Before trusting a green, mutate
  the thing under test and watch it go red.
