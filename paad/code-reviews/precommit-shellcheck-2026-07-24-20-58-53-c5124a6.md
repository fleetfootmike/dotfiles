# Agentic Code Review: precommit-shellcheck

**Date:** 2026-07-24 20:58:53
**Branch:** precommit-shellcheck -> main
**Commit:** c5124a62fa7b8ab2d410c3a68d9fa55373cfdb14
**Files changed:** 4 | **Lines changed:** +68 / -21
**Diff size category:** Small (scope expanded to full `git/hooks/pre-commit`)

## Executive Summary

The branch does exactly what its plan set out to do: it adds a `validate_bash`
shellcheck check (with a `bash -n` fallback), fixes the two latent
`exit`-instead-of-`return` bugs in the validators, and makes the `/dev/tty`
prompts safe to run headless. The **changes introduced on this branch are
clean** — no bugs were found in the new code, and it actually improves quoting
and control flow over what it replaced. No Critical or Important issues live in
the diff itself.

The findings below are all **pre-existing** robustness issues in the
surrounding hook (surfaced because the small diff let us review the whole file),
plus documentation drift where this branch changed behavior without updating
`CLAUDE.md`. The two worth acting on are the filename word-splitting in the main
loop (a genuinely broken file with a space in its name can commit unchecked
while the hook reports success) and the fragile deletion parse — both narrow
triggers, both long-standing.

## Critical Issues

None found.

## Important Issues

### [I1] Main loop word-splits filenames, so a broken file can slip through

- **File:** `git/hooks/pre-commit:136` (fallout at 157, 160, 163, 173, 176, 182)
- **Bug:** `for file in $(git diff --cached --name-only $against)` uses an
  unquoted command substitution, so filenames are split on `IFS` and
  glob-expanded. A staged path containing a space (or `*`/`?`) is broken into
  tokens; each token fails every pattern in `typeof`, resolves to `unhandled`,
  and is skipped at line 147. Nothing sets `BAD`, so `badFiles` stays empty and
  the hook prints `+++ pre-commit: all files OK` and `exit 0`. git also
  quote-escapes such paths (`core.quotePath`), compounding the mis-parse.
- **Impact:** A genuinely broken shell/Perl/YAML file whose name contains a
  space or glob character is committed **without ever being checked**, and the
  hook reports success. That is the exact miss a lint hook exists to prevent.
  Trigger is narrow (unusual filenames), which is why this is Important rather
  than Critical.
- **Suggested fix:** Iterate NUL-delimited and quote every expansion:
  `git diff --cached --name-only -z $against | while IFS= read -r -d '' file`.
  Mind the existing subshell-variable caveat already noted in the comment at
  lines 131-134 (accumulate `badFiles` via a temp file or `mapfile -d ''` array,
  not across a pipe).
- **Confidence:** High (verified: silent-skip-then-exit-0 confirmed by reading
  the loop and the final branch)
- **Pre-existing** (unchanged from `main`)
- **Found by:** Logic & Correctness, Error Handling, Contract & Integration,
  Security (4/5 specialists)

### [I2] Fragile staged-deletion detection

- **File:** `git/hooks/pre-commit:139`
- **Bug:** `if [ $(git status --porcelain $file | sed -e "s;$file;;" | sed -e
  's/ //g' ) == "D" ]`. The command substitution and `$file` are unquoted, and
  `==` is used inside single-bracket `[ ]`. Empty output expands to
  `[ == "D" ]` → bash `unary operator expected` (exit 2). A `$file` containing
  `;` or sed metacharacters corrupts the `s;$file;;` substitution. A staged
  rename (`R  old -> new`) mis-parses to a non-`D` string (benign, but only by
  accident).
- **Impact:** On unusual filenames the deletion-skip guard either errors out or
  mis-classifies. A staged deletion that misfires here is *not* skipped, so the
  loop runs a type validator (e.g. `perl -Ilib -cw`) against a path that no
  longer exists on disk → `BAD=true` → the commit is blocked with a confusing
  message. Normal `git rm foo.pl` works.
- **Suggested fix:** `status=$(git status --porcelain -- "$file")` then test the
  status column directly (or use `git diff --cached --name-only --diff-filter=D`
  to get the deleted set). Use `[ ... = ... ]`, not `==`, and quote the
  substitution.
- **Confidence:** Medium-High
- **Pre-existing** (unchanged from `main`)
- **Found by:** Logic & Correctness, Error Handling, Security (3/5 specialists)

## Suggestions

- **[S1] `CLAUDE.md` tty description is now stale.** `CLAUDE.md:30` says the hook
  "Requires a tty (`exec < /dev/tty`)"; the code now *probes* the tty and runs
  fail-closed when headless (`git/hooks/pre-commit:13-21`). Reword to describe
  the `INTERACTIVE` probe. *(Introduced this branch. Found by: Logic.)*
- **[S2] YAML fails closed on any yamllint finding, asymmetric with bash.**
  `validate_yaml` (lines 61-70) runs `yamllint` with no severity filter, so a
  headless commit is hard-blocked by benign 80-col/style nits — while
  `validate_bash` uses `shellcheck -S warning` to tolerate exactly that. Decide
  one policy (e.g. `yamllint`'s error-level only) or document the asymmetry as
  intentional. *(Partly introduced this branch. Found by: Error Handling.)*
- **[S3] Duplicated fail-closed/prompt block.** The
  "non-interactive → `return 1`, else y/n prompt loop" block is near-identical
  in `validate_yaml` (66-78) and `validate_bash` (98-111); extract a shared
  `ask_or_fail "<kind>"` helper to prevent drift. *(Introduced this branch.
  Found by: Contract.)*
- **[S4] Quoting inconsistency between sibling call sites.** `validate_yaml
  $file` (line 173, unquoted) vs `validate_bash "$file"` (line 168, quoted) —
  the new code quotes, the sibling does not. Quote all `$file` uses (157, 160,
  163, 173, 176, 182). Overlaps I1. *(Pre-existing. Found by: Contract, Logic.)*
- **[S5] `CLAUDE.md` markdownlint description overstates enforcement.**
  `CLAUDE.md:38` says ".md → markdownlint (enforces MD013, 80-col line length)",
  but the new `markdownlint.json` sets `MD013.code_blocks: false` (code blocks
  exempt), and the new config files aren't documented. Note the exemption and
  list the config. *(Introduced this branch. Found by: Contract.)*
- **[S6] Committed `.markdownlint.json` symlink vs no-leading-dots convention.**
  `CLAUDE.md:11` says config files are stored without leading dots (the dot is
  added at deploy time), yet a dotted `.markdownlint.json` symlink →
  `markdownlint.json` is tracked. It's functionally required (markdownlint
  auto-loads `.markdownlint.json` from cwd), so document the exception or pass
  `-c markdownlint.json` in the hook instead. *(Introduced this branch. Found
  by: Contract.)*
- **[S7] `template` type has no case arm → silent pass.** `typeof` returns
  `template` for `.tt`/`.tmpl` (line 36) but the `case` has no `template )` arm,
  so those files hit `* )` "assume OK" and pass unchecked. Drop the
  classification or add an explicit no-op arm. *(Pre-existing. Found by: Error
  Handling.)*
- **[S8] Hook sources working-tree `.perlenv` (`. .perlenv`, line 7).** Arbitrary
  code execution from repo contents when the hook runs in an untrusted checkout.
  Pre-existing and already documented in `CLAUDE.md` as intentional per-repo
  config; low practical risk since hooks aren't cloned. Listed for completeness.
  *(Pre-existing, by-design. Found by: Security.)*

## Plan Alignment

Plan doc: `docs/superpowers/plans/2026-07-24-precommit-shellcheck.md`

- **Implemented:** Every specified item is present and faithful — the
  `INTERACTIVE` tty probe (lines 15-21), `validate_yaml` using `return` +
  `$filename` + fail-closed (58-79), `validate_sql` returning instead of exiting
  (81-84), `validate_bash` with `shellcheck -S warning` and `bash -n` fallback
  and no `-s bash` flag (86-112), the `bash )` case rewired (165-169), and both
  `CLAUDE.md` doc updates (the `.sh` line and the `shellcheck` PATH entry).
  Coloured RED/BLUE/GREEN + `${NC}` style is used on all new echoes.
- **Not yet implemented (neutral, expected):** The tracked hook is not
  auto-installed into `.git/hooks/` — the plan's Post-implementation note
  declares this out of scope, and the live hook is confirmed still the pre-plan
  version. The interactive-override path (Task 2 Step 8) is a manual-only check.
- **Deviations:** Only cosmetic — an added `# shellcheck disable=SC2217`
  directive on line 16 (not in the plan text; benign, lets the hook self-lint
  clean) and minor comment rewordings. No behavioral contradictions.

## Review Metadata

- **Agents dispatched:** Logic & Correctness, Error Handling & Edge Cases,
  Contract & Integration, Security, Plan Alignment (5 specialists in parallel),
  then a single Verifier.
- **Scope:** Full `git/hooks/pre-commit` (scope expanded from the small diff),
  plus `CLAUDE.md`, `markdownlint.json`, and the `.markdownlint.json` symlink.
- **Raw findings:** 10 (before verification)
- **Verified findings:** 10 (all confirmed; none rejected)
- **Filtered out:** 0
- **Severity split:** 0 Critical, 2 Important, 8 Suggestions
- **Introduced-by-branch:** S1, S2, S3, S5, S6 (all Suggestion-level).
  Important issues I1 and I2 are pre-existing.
- **Steering files consulted:** `CLAUDE.md` (repo root), `~/.claude/CLAUDE.md`
- **Plan/design docs consulted:**
  `docs/superpowers/plans/2026-07-24-precommit-shellcheck.md`
