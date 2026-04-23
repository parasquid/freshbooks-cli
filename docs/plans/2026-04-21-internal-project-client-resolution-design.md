# Internal Project Client Resolution Design

Date: 2026-04-21
Issue: #2
Branch: `2-fb-log-requires-client-even-for-internal-projects`

## Summary

`fb log` currently forces client resolution before project resolution. That makes it impossible to log directly to an internal FreshBooks project, because those projects are represented by `internal: true` and `client_id: null`.

The same mismatch exists in `fb edit`: changing only the project keeps the old `client_id`, so moving an entry onto an internal project preserves an invalid client association.

This design updates both `log` and `edit` so project selection can drive client resolution when needed. Internal projects will be treated as clientless by omitting `client_id` from the API payload. A new explicit `--internal` flag will be added for commands where the user wants to say "this entry should have no client".

## Goals

- Allow `fb log --project "<internal project>" ...` to work without `--client`.
- Allow explicit client clearing from the CLI with `--internal`.
- Ensure `fb edit` can move an existing entry onto an internal project and end up with `client_id: null`.
- Keep normal cached/default client behavior for the existing client-first flows.
- Update help text and docs so internal-project behavior is obvious.
- Ensure read/display commands render internal projects and entries clearly.

## Non-Goals

- Refactor every selector in the CLI into a new shared abstraction.
- Change how FreshBooks auth, token refresh, or cache expiration works globally.
- Broaden the feature into full project/client consistency validation for unrelated commands.

## Verified Facts

### FreshBooks documentation

- Time entries expose an `internal` boolean meaning the entry is not assigned to a client.
- Projects expose an `internal` boolean.

Sources:
- https://www.freshbooks.com/api/time_entries
- https://www.freshbooks.com/api/project

### Live API behavior

Read-only checks against the current account confirmed:

- Internal projects are returned with `internal: true` and `client_id: null`.
- Existing time entries on internal projects are returned with `project_id` set, `client_id: null`, and `internal: false`.

Implication:

- For project-backed internal entries, the safe payload behavior is to omit `client_id`.
- This design should not force `internal: true` in the create/update payload for the internal-project path.

## Current Problem

### `log`

Current flow:

1. `select_client`
2. `select_project(client["id"], defaults)`
3. `select_service`
4. build payload with `"client_id" => client["id"]`

This prevents internal projects from ever being selected unless the user supplies an unrelated client, which produces incorrect data.

### `edit`

Current flow builds a full replacement payload from the existing entry, including:

- `client_id`
- `project_id`
- `service_id`

If the user changes only `--project`, the old `client_id` is preserved. Moving an entry from a client-backed project to an internal project therefore keeps the old client attached.

## CLI Contract

### New flag

Add `--internal` to:

- `fb log`
- `fb edit`

Semantics:

- `--internal` means the resulting entry should have no client association.
- `--internal` conflicts with `--client`.
- `--internal` requires `--project`, because this repo resolves services and internal status from a concrete project.

### Project-driven inference

If `--project` is passed without `--client`, the command will resolve the named project from a fresh all-projects fetch and derive client handling from the selected project:

- internal project: omit `client_id`
- client-backed project: use that project's `client_id`

This behavior applies to both `log` and `edit`.

### Mismatch handling

Abort with a clear error when:

- `--client` and `--internal` are both passed
- `--internal` is passed for a project that is not internal
- `--client` is passed together with a project whose FreshBooks data shows `internal: true` or `client_id: null`

## Resolution Strategy

Introduce a focused internal resolution step used by both `log` and `edit`.

### Normal client-first path

Keep the existing flow when:

- no `--project` is passed, and
- no `--internal` is passed

This preserves current defaults and cache behavior.

### Project-first path

Use a fresh all-projects lookup when:

- `--project` is passed without `--client`, or
- `--internal` is passed, or
- `edit` changes `--project`

Project-first resolution returns:

- the selected project
- whether the project is internal
- the effective client id, if any

Rules:

- A project is internal if `project["internal"] == true` or `project["client_id"].nil?`.
- For internal projects, the effective client id is absent.
- For non-internal projects, the effective client id is `project["client_id"]`.

## Command Behavior

### `fb log`

#### Existing behavior preserved

- `fb log --client "Acme" ...` continues to use the current client-first path.
- No-project logging without `--internal` continues to use cached/default client selection.

#### New behavior

- `fb log --project "<internal project>" ...` works without `--client`.
- `fb log --internal --project "<internal project>" ...` explicitly requests a clientless entry.
- `fb log --project "<client-backed project>" ...` may derive the client from that project even when `--client` is omitted.

Payload behavior:

- internal project: include `project_id` and optional `service_id`, omit `client_id`
- client-backed project: include `client_id`, `project_id`, and optional `service_id`

### `fb edit`

#### Existing behavior preserved

- `fb edit --id <id> --client "Acme" ...` continues to set `client_id` explicitly.
- Edits that do not touch project/client fields keep their current semantics.

#### New behavior

- `fb edit --id <id> --project "<internal project>" ...` updates the entry so `client_id` is omitted from the update payload.
- `fb edit --id <id> --internal --project "<internal project>" ...` does the same explicitly.
- `fb edit --id <id> --project "<client-backed project>" ...` synchronizes `client_id` to the selected project's client when no explicit `--client` is given.

This keeps project/client relationships coherent and makes the manual real-world verification possible.

### Read and display support

These commands do not need new flags, but they should render internal records clearly:

- `entries`
- `status`
- interactive entry pickers used by `edit` and `delete`
- `projects`

Rules:

- internal entries should display `Internal` as the client label instead of blank output
- internal projects should display `Internal` in project listings instead of `-`
- per-client summaries should group internal entries under `Internal`

## Services

Service resolution stays project-scoped.

Rules:

- If the selected project includes embedded `services`, use that list.
- Internal projects still use their own project services.
- No new service-selection model is introduced.

## Cache Policy

The repo currently caches raw project data for 10 minutes. Internal detection is more sensitive to stale project metadata than the existing client-first flow, so project-driven internal resolution will bypass the normal cache only when needed.

Fresh fetch required for:

- `log` with `--internal`
- `log` with `--project` and no `--client`
- `edit` when `--project` is being changed

Normal cache behavior preserved for:

- client-first `log`
- commands unrelated to project-driven internal detection

Additional rule:

- never persist `nil` as a cached or default `client_id`

## Defaults Behavior

Defaults should continue to store only concrete IDs.

Rules:

- internal runs may save `project_id` and `service_id`
- internal runs must not save `client_id: nil`
- normal client-backed runs keep saving `client_id`, `project_id`, and `service_id` as today

This avoids stale default-client reuse while keeping useful project/service defaults.

## Error Handling

Use clear aborts for:

- project not found
- internal flag used without a project
- internal flag used with a non-internal project
- explicit client combined with an internal project
- service not found in the selected project's services

Error messages should state the exact mismatch so the user can correct the command without guessing.

## Testing

### Automated repo tests

Add CLI specs covering:

- `log` with `--project` pointing to an internal project and no `--client`
- `log` with `--internal --project <internal>`
- `log` conflict: `--client` with `--internal`
- `log` conflict: explicit client with an internal project
- `edit` moving an entry onto an internal project by changing only `--project`
- `edit` with `--internal --project <internal>`
- `edit` moving an entry onto a client-backed project and syncing `client_id`
- defaults persistence for internal runs without storing `client_id: nil`
- forced fresh project resolution on internal/project-driven paths

Assertions should verify payload shape, especially that internal-project requests omit `client_id`.

### Manual verification

Manual verification will be done by intentionally editing one existing meeting entry that is currently parked on a client-backed project and moving it onto an internal project.

Verification steps:

1. Identify one existing meeting entry currently attached to a client-backed project.
2. Edit it to use the intended internal project.
3. Read the updated entry back through `fb entries --format json`.
4. Confirm the resulting record has:
   - the internal `project_id`
   - `client_id: null`

This verification is intentionally manual and not automated in the test suite.

## Documentation And Help Updates

Update all user-facing guidance that currently implies `--client` is always required.

Files expected to change:

- CLI help text in `lib/freshbooks/cli.rb`
- `README.md`
- `AGENTS.md`
- `skills/freshbooks/SKILL.md`

Documentation must explain:

- what `--internal` means
- that internal projects can be logged without `--client`
- that internal entries and projects display as `Internal` in CLI output
- that project-driven internal detection uses a fresh project lookup
- that normal client-first flows still use cached/default behavior
- that `edit` also supports moving entries onto internal projects

## Risks

- Project title matching remains name-based and can still be ambiguous if duplicate titles exist.
- Forced fresh project fetches add a small extra API cost on the internal/project-driven paths.
- The existing token refresh race can interfere with live verification if commands are run in parallel; verification should be done serially.

## Recommended Implementation Shape

Keep the change narrow:

- add a shared project/client resolution helper for `log` and `edit`
- do not refactor the entire command layer
- update payload construction and defaults handling only where internal-project behavior requires it

This keeps the change aligned with issue #2 while fixing the adjacent `edit` inconsistency required for real-world verification.
