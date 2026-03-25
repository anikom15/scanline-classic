# CI/CD 30-Day Rollout Plan

## Purpose
This document defines a practical 30-day roadmap for expanding CI/CD in Scanline Classic while preserving the current stable baseline:
- Strict shader lint gate already enforced through build path.
- Build orchestration through `build.py` and trim packaging through `build-trim.py`.

## Current Baseline (Day 0)
- Workflow: `.github/workflows/shader-lint.yml`
- Gate behavior:
  - Default: `python build.py --lint-shaders --jobs 1`
  - Strict on `master` pushes and PRs targeting `master`: `python build.py --lint-shaders --strict-structure --jobs 1`

## 30-Day Goals
1. Keep PR feedback fast and deterministic.
2. Increase confidence with deeper scheduled validation.
3. Make build outputs easy to review and consume.
4. Prepare repeatable release-grade packaging.
5. Add governance and hygiene controls (branch policy, ownership, dependency checks).

## Phase Plan

### Week 1: CI Artifacts + Policy Hardening
**Scope**
- Keep current lint gate workflow as-is.
- Add artifact upload on `master` pushes for generated outputs.
- Enable/verify branch protections and required checks.

**Deliverables**
- New or updated workflow step to upload:
  - `out/` (required)
  - `out-trim/` (optional if generated in same job)
- Repository settings aligned:
  - Required status check: Build Lint Gate
  - Require PR review before merge
  - Block direct pushes to `master`

**Exit Criteria**
- Every `master` push has downloadable artifacts.
- No unreviewed merges to `master`.

---

### Week 2: Nightly Full Validation
**Scope**
- Add scheduled workflow (`cron`) for full validation depth.
- Include strict lint + full build + trim build.

**Suggested job flow**
1. `python build.py --lint-shaders --strict-structure --jobs 1`
2. `python build-trim.py`
3. Upload both `out/` and `out-trim/` artifacts.

**Deliverables**
- New workflow: nightly full build.
- Failure notifications routed to maintainers.

**Exit Criteria**
- Nightly run completes successfully for at least 5 consecutive nights.
- Failures produce actionable logs and artifacts.

---

### Week 3: Release Pipeline (Tag-Driven)
**Scope**
- Add release workflow triggered by semantic tags (for example `v*`).
- Build production artifacts and publish release assets.

**Suggested release assets**
- `scanline-classic-out.zip` (from `out/`)
- `scanline-classic-out-trim.zip` (from `out-trim/`)
- `checksums.txt` (SHA256)

**Deliverables**
- New tag-triggered workflow.
- Automated GitHub Release creation with attached assets.

**Exit Criteria**
- Creating a test tag produces complete release assets without manual packaging.

---

### Week 4: Reproducibility + Hygiene Automation
**Scope**
- Add reproducibility checks for generated outputs.
- Add dependency and workflow security hygiene automation.

**Suggested checks**
- Rebuild key outputs twice in CI and compare file hashes for determinism.
- Add weekly dependency audit job (Python dependencies and GitHub Action pin hygiene).
- Add path-based job filters to skip heavy jobs on docs-only changes.

**Deliverables**
- Determinism check job for critical generated directories.
- Weekly hygiene workflow.
- Path filters in relevant workflows.

**Exit Criteria**
- Determinism check passes on baseline branch.
- Hygiene jobs run weekly and generate actionable reports.

## Recommended Operating Model

### PR Pipeline (Fast)
- Trigger: pull_request
- Focus:
  - Strict lint gate via build path
  - Minimal compute time
- Target runtime: under 10 minutes

### Nightly Pipeline (Deep)
- Trigger: schedule
- Focus:
  - Full strict validation
  - Build + trim + artifact retention

### Release Pipeline (Deterministic)
- Trigger: tag push
- Focus:
  - Reproducible packaging
  - Checksum generation
  - Published release assets

## Ownership and Cadence
- CI workflow ownership: maintainers responsible for scripts/build pipeline.
- Review cadence: weekly triage of CI failures and flaky behavior.
- Change control: any workflow/script change must include:
  - updated docs
  - local reproduction command
  - expected CI impact

## Metrics to Track
1. PR success rate (% passing on first run)
2. Median PR CI duration
3. Nightly failure frequency
4. Mean time to fix CI failures
5. Release pipeline success rate

## Risks and Mitigations
- **Risk:** CI runtime growth slows contributor feedback.
  - **Mitigation:** keep fast PR pipeline separate from nightly deep checks.
- **Risk:** Nondeterministic generation causes flaky checks.
  - **Mitigation:** add reproducibility/hash comparison and isolate unstable steps.
- **Risk:** Artifact size growth impacts cost/performance.
  - **Mitigation:** retention limits and selective artifact publishing.

## Immediate Next Actions
1. Implement Week 1 artifact upload on `master` push.
2. Enable branch protections with required Build Lint Gate status.
3. Scaffold nightly full-validation workflow.

## Reference Commands
- Strict lint gate build:
  - `python build.py --lint-shaders --strict-structure --jobs 1`
- Trim build:
  - `python build-trim.py`
