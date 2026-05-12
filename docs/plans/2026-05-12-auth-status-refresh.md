# Auth Status Refresh Implementation Plan

**Goal:** Make `fb auth status` report whether browser re-auth is actually required, not merely whether the access token is stale.

**Architecture:** Keep token refresh behavior in `FreshBooks::CLI::Auth`, reusing the existing locked refresh path. `auth_status` will attempt a silent refresh when config and expired tokens are present, then return status based on the post-refresh token state. If refresh is impossible or fails, status remains reportable and includes `requires_reauth: true`.

**Tech Stack:** Ruby, Thor, HTTParty, RSpec, rspec-given, WebMock.

---

### Task 0: Post This Design To Issue #17

**Files:**
- Read: `docs/plans/2026-05-12-auth-status-refresh.md`

- [ ] Post the full text of this plan to GitHub issue #17 as a comment.

Run:

```bash
gh issue comment 17 --repo parasquid/freshbooks-cli --body-file docs/plans/2026-05-12-auth-status-refresh.md
```

Expected: GitHub accepts the comment.

### Task 1: Add Failing Auth Specs

**Files:**
- Modify: `spec/freshbooks/auth_spec.rb`

- [ ] Add coverage showing `auth_status` silently refreshes stale tokens when a refresh token and config exist.
- [ ] Add coverage showing `auth_status` reports `requires_reauth: true` without aborting when refresh fails.

Run:

```bash
bundle exec rspec spec/freshbooks/auth_spec.rb:450
```

Expected before implementation: failures showing `tokens_expired` remains true and/or refresh failure aborts.

### Task 2: Implement Silent Refresh In Auth Status

**Files:**
- Modify: `lib/freshbooks/auth.rb`

- [ ] Update `auth_status` to load config and tokens, attempt `refresh_token_with_lock(config, tokens)` when tokens are expired and config exists, and return refreshed token status when successful.
- [ ] Add `requires_reauth` to the returned hash. It should be true when config is missing, tokens are missing, tokens remain expired after refresh, or refresh fails.
- [ ] Rescue `SystemExit` from refresh failure so `fb auth status` can report status instead of terminating early.

Run:

```bash
bundle exec rspec spec/freshbooks/auth_spec.rb:450
```

Expected after implementation: focused auth status specs pass.

### Task 3: Add CLI Status Coverage

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`

- [ ] Add or update CLI specs to prove `fb auth status --format json` includes `requires_reauth`.
- [ ] Add or update table-output specs to prove `fb auth status` shows whether re-auth is required.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:1180
```

Expected: focused CLI auth status specs pass.

### Task 4: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `skills/freshbooks/SKILL.md`

- [ ] Document that `fb auth status` may silently refresh expired access tokens.
- [ ] Document that scripted callers should branch on `requires_reauth`, not `tokens_expired`.
- [ ] Update FreshBooks skill auth guidance to try normal reads or branch on `requires_reauth` before asking for browser OAuth.

### Task 5: Full Verification

**Files:**
- No source edits.

- [ ] Run the full test suite.

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
