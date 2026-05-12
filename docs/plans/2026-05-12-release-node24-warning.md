# Release Node 20 Warning Cleanup Plan

**Goal:** Remove the GitHub Actions Node 20 deprecation warning from the release workflow and document RubyGems verification as part of release success.

**Architecture:** Keep the existing release workflow and trusted publishing action. Since `rubygems/release-gem` is already on its latest release, opt the workflow into Node 24 JavaScript action execution using the runner-supported environment flag. Update durable repo guidance so releases are verified on GitHub Actions, GitHub Releases, git tags, and RubyGems.

**Tech Stack:** GitHub Actions, RubyGems trusted publishing, Ruby.

---

### Task 0: Post This Design To Issue #24

**Files:**
- Read: `docs/plans/2026-05-12-release-node24-warning.md`

- [ ] Post the full text of this plan to GitHub issue #24 as a comment.

Run:

```bash
gh issue comment 24 --repo parasquid/freshbooks-cli --body-file docs/plans/2026-05-12-release-node24-warning.md
```

Expected: GitHub accepts the comment.

### Task 1: Opt Release Workflow Into Node 24

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] Add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` at workflow scope so JavaScript actions in the release job run on Node 24 before the platform default changes.

### Task 2: Document Release Verification

**Files:**
- Modify: `AGENTS.md`

- [ ] Update release guidance to say a release is successful only after all of these are verified: release workflow success, GitHub Release exists, `vX.Y.Z` tag exists, and RubyGems reports the new `freshbooks-cli` version.

### Task 3: Verify

**Files:**
- No source edits.

- [ ] Run the test suite.

Run:

```bash
bundle exec rspec
```

Expected: `0 failures`.

- [ ] Run whitespace verification.

Run:

```bash
git diff --check
```

Expected: no output.
