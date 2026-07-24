# Pre-commit shellcheck: design

## Goal

Make the `git/hooks/pre-commit` template lint shell files with `shellcheck`
instead of the current bare `bash -n` syntax check, while staying usable on
machines that don't have shellcheck installed.

## Background

The hook detects shell files two ways: by `*.sh` extension, and by a
`#!...bash` shebang for extension-less files (so the repo's own `bashrc`,
`bash_profile`, etc. are covered). Today the `bash` case runs `bash -n "$file"`,
which only catches outright syntax errors and misses quoting bugs, unset
variables, and the rest of what shellcheck finds.

While reading the hook I found two problems worth fixing in the same pass.

First, `validate_yaml` and `validate_sql` call `exit` rather than `return`.
Because they run as plain functions (not in a subshell), that `exit` ends the
whole hook, not just the function. The first YAML file that passes therefore
makes the hook exit 0 and silently skip every remaining staged file and the
failure summary. `typeof` uses `exit` safely only because it runs inside
`$(...)`.

Second, the hook does an unconditional `exec < /dev/tty` and then reads answers
from it in the override prompts. With no controlling terminal (CI, an agent, a
scripted commit) that redirect errors, and the subsequent `read` hits EOF and
spins the "please answer yes or no" `case` forever. The hook hangs in any
non-interactive context today, and the new shellcheck prompt would inherit the
same hang.

## Behavior

Add a `validate_bash "$file"` function shaped like `validate_yaml`, but using
`return`, not `exit`:

- If `command -v shellcheck` succeeds, run `shellcheck -S warning "$file"`.
  - Clean: `return 0`.
  - Findings: print shellcheck's output, then run the same yes/no
    "commit this anyway?" prompt loop the YAML check uses. Yes returns 0, no
    returns 1.
- If shellcheck is not on PATH, print a one-line notice that it's falling back,
  then run `bash -n "$file"`. Pass returns 0; a syntax error returns 1 with no
  prompt, since a syntax error is unambiguous.

`-S warning` keeps the check focused on real and likely bugs and skips pure
style nits like SC2086, which the existing dotfiles trip constantly. The prompt
loop means a warning is a speed bump, not a wall: the author can look and
proceed, matching how the YAML check already behaves.

No `-s bash` flag. shellcheck reads the shebang by default, so a genuine POSIX
`sh` script is linted as `sh` rather than being forced through bash rules.

### Terminal handling

Replace the blind `exec < /dev/tty` with a probe that actually tries to open the
terminal, since in some environments the `/dev/tty` node exists but opening it
fails with `ENXIO`:

```bash
INTERACTIVE=0
if { true < /dev/tty; } 2>/dev/null; then
    exec < /dev/tty
    INTERACTIVE=1
fi
```

Every override prompt (`validate_yaml` and the new `validate_bash`) branches on
`INTERACTIVE`. When it's set, the existing `read yn` loop runs unchanged. When
it isn't, the function prints a coloured notice in the hook's existing style
(`echo -e "${RED}???${NC} pre-commit: ..."`) and returns 1, so an unattended
warning blocks the commit instead of hanging. `git commit --no-verify` remains
the documented escape hatch for automation that must skip the checks.

Failing closed is the deliberate choice: with no human to judge a lint warning,
blocking is safer than allowing, and it makes the check authoritative in CI.

## Changes

1. New `validate_bash` function (uses `return`).
2. The `bash )` case calls
   `validate_bash "$file" && echo "Bash syntax OK" || BAD=true`, so a failure
   flows through the existing `$badFiles` accounting instead of the old inline
   `bash -n`.
3. Update the now-stale comment above the `bash` case (it currently says the
   check won't catch missing external commands).
4. Fix `validate_yaml` and `validate_sql` to `return` instead of `exit`, so a
   passing or overridden YAML file no longer aborts checks on later files.
5. Replace the unconditional `exec < /dev/tty` with the `INTERACTIVE` probe
   above, and branch both prompt loops on it: prompt when interactive, else
   print a coloured notice and `return 1`. This also repairs the existing
   YAML-prompt hang in non-interactive contexts.
6. Add `shellcheck` to the hook's assumed-on-PATH dependency list in the repo's
   CLAUDE.md, noting the `bash -n` fallback.

New notices reuse the hook's colour variables (`RED`/`BLUE`/`GREEN`/`NC`) and
the `echo -e "${COLOUR}...${NC} pre-commit: ..."` format, to stay consistent
with the surrounding messages.

## Testing

There is no test harness for the hook, so verification is manual, run against a
scratch git repo with the hook installed (the template blocks commits on
`main`/`master`, so test on a feature branch). Thanks to the fail-closed
`INTERACTIVE` branch, all but one of these run headless (no tty):

- Headless: a clean shell file passes without a prompt.
- Headless: a shell file with a real shellcheck warning (e.g. an unquoted
  `rm $var`) hits the non-interactive branch and blocks the commit (`return 1`),
  showing the coloured notice.
- Headless: with shellcheck removed from PATH, a syntactically bad file fails via
  `bash -n` and a clean one passes, with the fallback notice shown.
- Headless: two staged YAML files, the first valid: confirm the second is still
  checked (proves the exit-to-return fix).
- Interactive (real terminal, manual): the same shellcheck-warning file triggers
  the prompt; "no" aborts, "yes" lets it through.

## Out of scope

Per-repo `.shellcheckrc` config, disabling specific SC codes, and linting
languages other than shell.
