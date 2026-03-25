# Shader Authoring Checklist

Use this checklist for both human edits and Copilot-generated edits.

## Scope and file type
- [ ] `.slang` files are full shaders and must define exactly one vertex stage and one fragment stage.
- [ ] `.inc` files are include-only and must not contain `#pragma stage vertex` or `#pragma stage fragment`.

## Required section flow in `.slang`
- [ ] Universal declarations appear first.
- [ ] Vertex shader section appears next.
- [ ] Fragment shader section appears last.
- [ ] Exactly one `#pragma stage vertex` exists.
- [ ] Exactly one `#pragma stage fragment` exists.

## Push/UBO ordering and sizing
- [ ] Block order follows: parameter pragmas -> push block definition -> push semantic defines -> UBO definition -> UBO semantic defines.
- [ ] Push block maximum possible size (across conditional compilation paths) is <= 128 bytes.
- [ ] If push block max size is < 128 bytes and UBO has non-`MVP` semantics, move suitable semantics toward push constants to approach 128 bytes.

## Universal declaration placement
- [ ] Universal functions/variables are genuinely shared by both vertex and fragment stages.
- [ ] Declarations used by only one stage are moved into that stage section.

## Formatting and style
- [ ] K&R brace style for control-flow blocks (`if/else/for/while/switch/do`).
- [ ] No trailing whitespace.
- [ ] No mixed tabs/spaces in the same indentation run.
- [ ] No excessive blank-line runs.
- [ ] File ends with a newline.

## Validation commands
- [ ] Run `python scripts/lint_shaders.py`.
- [ ] For build validation, run `python build.py` (or `python build.py --lint-shaders` when shader lint gating is desired).
