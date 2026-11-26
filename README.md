# github-to-gitea-auto-migration-tool

A configuration-driven migration tool that moves a GitHub account (personal
repositories, organization repositories, gists, webhooks, deploy keys, and
GitHub Projects v2 boards) into a self-hosted Gitea instance.

The tool is written in bash and depends only on `curl`, `jq`, and (optionally)
`git` / `git-lfs`. The implementation is split across `lib/*.sh` modules that
`run.sh` sources, so each migration step is independently reviewable.

---

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Required variables](#required-variables)
  - [Safety flags](#safety-flags)
  - [Migration flags](#migration-flags)
  - [Overwrite flags](#overwrite-flags)
  - [Behavior flags](#behavior-flags)
  - [Token scopes](#token-scopes)
- [Usage](#usage)
- [Architecture](#architecture)
- [What gets migrated](#what-gets-migrated)
- [What does _not_ get migrated](#what-does-not-get-migrated)
- [Destructive operations](#destructive-operations)
- [Verification](#verification)
- [Output and logging](#output-and-logging)
- [Troubleshooting](#troubleshooting)
- [Exit codes](#exit-codes)
- [License](#license)

---

## Overview

`run.sh` reads a `.env` file, authenticates against GitHub and Gitea, and
walks your account (and any organizations you are an active member of),
migrating repositories, webhooks, deploy keys, gists, and Projects v2 boards.

The tool is designed to be **safe by default**:

- Existing Gitea repositories are **skipped** unless `SYNC_EXISTING=git`.
- Public GitHub repos stay public on Gitea by default (`FORCE_PRIVATE=false`);
  private sources always stay private.
- Destructive `OVERWRITE_*` flags are **off** unless explicitly enabled and
  confirmed — either interactively by typing `DELETE`, or via `--yes`.
- A `--dry-run` mode reads everything but never writes to Gitea.
- The `DELETE` confirmation prompt fires **before** the log file is opened,
  so it is never swallowed by `tee` buffering.

---

## Features

- **Full repository migration** via Gitea's `/api/v1/repos/migrate` endpoint,
  including issues, pull requests, releases, labels, milestones, and wiki.
- **Organization migration** with optional overwrite (deletes and recreates the
  org, its repos, and its webhooks), and configurable visibility for newly
  created orgs.
- **Gist migration** as private/public Gitea repositories; secret (unlisted)
  gists are always made private.
- **Webhook migration** (repo-level and org-level) with GitHub → Gitea event
  mapping; unsupported events are skipped with a warning rather than mapped
  incorrectly.
- **Deploy key migration** with the read-only flag preserved.
- **GitHub Projects v2 → Gitea project boards**, using a configurable
  single-select field (`PROJECTS_STATUS_FIELD`) as board columns, and a
  `No Status` column for items without a value.
- **Git-based sync** for existing repos (`SYNC_EXISTING=git`) — force-updates
  branches/tags and prunes refs absent on GitHub.
- **LFS re-push** (`OVERWRITE_LFS=true`) — re-fetches all LFS objects from
  GitHub and pushes them to Gitea. Never deletes existing LFS objects.
- **Verification** (`VERIFY`, `VERIFY_ALL`) — compares item counts between
  GitHub (GraphQL `totalCount`) and Gitea (`X-Total-Count` headers).
- **Rate-limit awareness** — automatically sleeps when GitHub quota is nearly
  exhausted or a 403/429 is returned.
- **Token safety** — credentials are written to a `umask 077` temp file and
  referenced via `-H @file`; they never appear in `curl` argv.
- **Structured output** — per-item log, comprehensive summary, warnings
  section, and a non-zero exit code when any item failed.

---

## Requirements

- `bash` 3.2+
- `curl` 7.55+
- `jq` 1.5+
- `git` (only if `SYNC_EXISTING=git` or `OVERWRITE_LFS=true`)
- `git-lfs` (only if `OVERWRITE_LFS=true`)
- Gitea **28.4.0+** with the Projects unit enabled (only for project migration)

---

## Quick start

1. Copy `example.env` to `.env` and fill in the required values.
2. Make the script executable:

   ```bash
   chmod +x run.sh
   ```

3. Do a dry run first:

   ```bash
   ./run.sh --dry-run
   ```

4. Review the summary, then run for real:

   ```bash
   ./run.sh
   ```

If any destructive `OVERWRITE_*` flag is enabled (other than `OVERWRITE_LFS`)
or `SYNC_EXISTING=git`, you will be asked to type `DELETE` to confirm. In a
non-interactive shell, pass `--yes` (or set `ASSUME_YES=true`).

---

## Configuration

All configuration lives in `.env` in the script directory (override with
`ENV_FILE=/path/to/file ./run.sh`).

### Required variables

| Variable       | Description                                                         |
| -------------- | ------------------------------------------------------------------- |
| `GITHUB_USER`  | Your GitHub username. Must match the authenticated account.         |
| `GITHUB_TOKEN` | GitHub token (see [Token scopes](#token-scopes)).                   |
| `GITEA_URL`    | Base URL of your Gitea instance (e.g. `https://gitea.example.com`). |
| `GITEA_USER`   | Gitea username that owns migrated personal repos/gists.             |
| `GITEA_TOKEN`  | Gitea API token with repo/org/project/admin scopes.                 |

`GITEA_URL` must use `https://` unless `ALLOW_INSECURE_HTTP=true` is set
(intended only for trusted isolated networks).

### Safety flags

| Variable              | Default | Purpose                                                                                                                                 |
| --------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `FORCE_PRIVATE`       | `false` | Force destination repos/gists/orgs private. Private sources always stay private.                                                        |
| `ORG_VISIBILITY`      | `auto`  | `auto` \| `private` \| `limited` \| `public` for newly created Gitea orgs. `auto` → `private` when `FORCE_PRIVATE=true`, else `public`. |
| `ALLOW_INSECURE_HTTP` | `false` | Permit plain HTTP to Gitea (trusted isolated networks only).                                                                            |

`FORCE_PRIVATE=true` together with `ORG_VISIBILITY=public` or
`ORG_VISIBILITY=limited` is rejected as a configuration error.

### Migration flags

Each category can be independently disabled. Defaults to `true`.

| Variable                | Migrates                                  |
| ----------------------- | ----------------------------------------- |
| `MIGRATE_REPOS`         | Personal repositories                     |
| `MIGRATE_ORGS`          | Organizations and their repos             |
| `MIGRATE_GISTS`         | Gists                                     |
| `MIGRATE_ISSUES`        | Issues (within repos)                     |
| `MIGRATE_PULL_REQUESTS` | Pull requests (within repos)              |
| `MIGRATE_RELEASES`      | Releases                                  |
| `MIGRATE_LABELS`        | Labels                                    |
| `MIGRATE_MILESTONES`    | Milestones                                |
| `MIGRATE_WIKI`          | Wiki pages                                |
| `MIGRATE_LFS`           | Git LFS objects                           |
| `MIGRATE_PROJECTS`      | GitHub Projects v2 → Gitea project boards |
| `MIGRATE_WEBHOOKS`      | Repo webhooks                             |
| `MIGRATE_ORG_WEBHOOKS`  | Org webhooks                              |
| `MIGRATE_DEPLOY_KEYS`   | Deploy keys                               |

### Overwrite flags

Defaults to `false`. Enabling any of these makes the operation destructive on
the Gitea side. Every `OVERWRITE_*` flag **except** `OVERWRITE_LFS`, plus
`SYNC_EXISTING=git`, requires typing `DELETE` (or `--yes` /
`ASSUME_YES=true`) before the run starts.

| Variable                 | Effect                                                                                               |
| ------------------------ | ---------------------------------------------------------------------------------------------------- |
| `OVERWRITE_REPOS`        | Delete and re-migrate existing repos.                                                                |
| `OVERWRITE_ORGS`         | Delete the org **and all repos inside it**, then recreate.                                           |
| `OVERWRITE_GISTS`        | Delete and re-migrate existing gist repos.                                                           |
| `OVERWRITE_PROJECTS`     | Delete and recreate project boards matched by the script's source marker.                            |
| `OVERWRITE_WEBHOOKS`     | Delete and recreate repo webhooks.                                                                   |
| `OVERWRITE_ORG_WEBHOOKS` | Delete and recreate org webhooks.                                                                    |
| `OVERWRITE_DEPLOY_KEYS`  | Delete and recreate deploy keys.                                                                     |
| `OVERWRITE_LFS`          | Re-fetch and push **all** LFS objects to existing repos (deletes nothing; needs `MIGRATE_LFS=true`). |

### Behavior flags

| Variable                | Default                     | Purpose                                                   |
| ----------------------- | --------------------------- | --------------------------------------------------------- |
| `SYNC_EXISTING`         | `skip`                      | `skip` or `git` (force-update branches/tags, prune refs). |
| `VERIFY`                | `true`                      | Verify migrated repos after creation.                     |
| `VERIFY_ALL`            | `false`                     | Also verify pre-existing repos during `SYNC_EXISTING`.    |
| `HOOKS_CREATE_INACTIVE` | `true`                      | Create webhooks as inactive on Gitea.                     |
| `GITHUB_AFFILIATION`    | `owner`                     | `owner`, `collaborator`, or `owner,collaborator`.         |
| `GH_MAX_WAIT`           | `3700`                      | Max seconds to sleep for a GitHub rate-limit reset.       |
| `PROJECTS_STATUS_FIELD` | `Status`                    | Single-select field used as board columns.                |
| `DRY_RUN`               | `false`                     | Same as `--dry-run`.                                      |
| `ASSUME_YES`            | `false`                     | Same as `--yes`.                                          |
| `LOG_FILE`              | `migration-<timestamp>.log` | Log file path.                                            |

Booleans accept `true`/`false`, `1`/`0`, and `yes`/`no`/`y`/`n`
(case-insensitive).

### Token scopes

**GitHub classic PAT** should include:

- `repo` — repositories, issues, PRs, webhooks, deploy keys
- `read:org` — organization listings and org webhooks
- `admin:repo_hook`, `admin:org_hook` — repo and org webhooks
- `gist` — gist migration
- `read:project` — Projects v2 boards

**Gitea token** must allow creating repos/orgs, managing webhooks and deploy
keys, and managing projects. If you migrate projects and `GITEA_USER` differs
from the token account, the script will refuse to run (unless projects are
disabled).

| Token          | Required scopes                                                                               |
| -------------- | --------------------------------------------------------------------------------------------- |
| `GITHUB_TOKEN` | `repo`, `read:org`, `admin:repo_hook`, `admin:org_hook`, `gist`, `read:project` (classic PAT) |
| `GITEA_TOKEN`  | `read:user`, `write:user` (Projects), `write:repository`, `write:organization`                |

---

## Usage

```
Usage: ./run.sh [--dry-run] [--yes]

  --dry-run   Read everything, change nothing on Gitea
              (counts = planned actions)
  --yes       Skip confirmation for destructive OVERWRITE_* flags and
              SYNC_EXISTING=git
  -h, --help  Show usage
```

The script also accepts `ENV_FILE=/path/to/file` to load a different
configuration file.

---

## Architecture

`run.sh` is a thin entrypoint; each migration step lives in its own module
under `lib/`. Every module is `source`d into `run.sh` so configuration,
counters, temp files, and failure trackers are shared. **Do not execute files
under `lib/` directly.**

| Module             | Purpose                                                            |
| ------------------ | ------------------------------------------------------------------ |
| `lib/config.sh`    | Load `.env`, apply defaults, validate, prompt for destructive ops. |
| `lib/logging.sh`   | Log file, temp dir, credential files, counters.                    |
| `lib/utils.sh`     | Counter, HTTP class test, failure/warning trackers.                |
| `lib/http.sh`      | Rate-limit-aware, token-safe, dry-run-aware HTTP client.           |
| `lib/preflight.sh` | Auth checks and Gitea capability probe.                            |
| `lib/git_sync.sh`  | Mirror-based branch/tag sync + LFS re-push.                        |
| `lib/repos.sh`     | Per-repo migration and existing-repo sync.                         |
| `lib/orgs.sh`      | Org creation/overwrite, org webhooks, org repos.                   |
| `lib/gists.sh`     | Gist → Gitea repository migration.                                 |
| `lib/projects.sh`  | Projects v2 → Gitea project boards.                                |
| `lib/webhooks.sh`  | Repo/org webhook migration and event mapping.                      |
| `lib/keys.sh`      | Deploy key migration.                                              |
| `lib/verify.sh`    | Post-migration count verification.                                 |
| `lib/summary.sh`   | Final execution summary and exit code.                             |

### Notes

- `lib/config.sh` runs **before** `lib/logging.sh`, so the `DELETE`
  confirmation prompt is not buffered by `tee`.
- `lib/logging.sh` installs the `EXIT` trap that cleans up `$TMP_DIR`, which
  holds the token header files and the `GIT_ASKPASS` script.
- `lib/projects.sh` matches existing Gitea boards by a
  `<!-- github-project-id:… -->` marker written into the board description,
  so `OVERWRITE_PROJECTS` never deletes an unrelated board that happens to
  share a title. Boards that fail structurally are rolled back so the next
  run retries cleanly.
- `lib/http.sh` keeps paging Gitea until it returns an empty array, because
  the server may clamp `limit=50` via `api.MAX_RESPONSE_ITEMS`; a short Gitea
  page is therefore not proof of the last page.
- `lib/orgs.sh` applies `ORG_VISIBILITY` only to newly created orgs. Existing
  orgs are only ever tightened to `private`, never made more public.

---

## What gets migrated

- Personal repos (filtered via `GITHUB_AFFILIATION`)
- Organization repos (for every org you are an active member of)
- Gists → private/public Gitea repos (`gist-<slug>-<id>`)
- Repo and org webhooks (with event translation)
- Repo deploy keys
- GitHub Projects v2 boards → Gitea project boards
- Issues, PRs, releases, labels, milestones, wiki (via Gitea migration API)
- Optional: branch/tag sync and LFS re-push for existing repos

---

## What does _not_ get migrated

- **Webhook secrets** (GitHub never returns them — re-enter manually)
- **Classic (pre-v2) project boards** (sunset by GitHub)
- **Projects v2 views**, custom fields other than `PROJECTS_STATUS_FIELD`,
  workflows/automations, draft items, and items owned by a different
  repository owner than the project
- **Actions** secrets/variables/runs (workflow files travel with the repo)
- **Branch protection rules, rulesets, CODEOWNERS enforcement**
- **Collaborators, teams, org members, permissions**
- **Discussions, Packages, Pages, Dependabot settings**
- **Stars, watchers, followers, repo topics, avatars**
- **Repos you are only a collaborator on** (set
  `GITHUB_AFFILIATION=owner,collaborator`)
- **Private repos the token cannot see** (e.g. org SSO not authorized)
- **LFS objects that already exist on Gitea** (same OID = same content)

---

## Destructive operations

When any of the following are enabled, the script **refuses to proceed**
without confirmation:

- `OVERWRITE_REPOS`
- `OVERWRITE_ORGS` — **deletes the org and every repo inside it**
- `OVERWRITE_GISTS`
- `OVERWRITE_WEBHOOKS`
- `OVERWRITE_ORG_WEBHOOKS`
- `OVERWRITE_DEPLOY_KEYS`
- `OVERWRITE_PROJECTS`
- `SYNC_EXISTING=git` — force-updates destination refs and prunes refs absent
  on GitHub

In an interactive shell you must type `DELETE`. In a non-interactive shell
you must pass `--yes` / `ASSUME_YES=true`. The prompt fires **before** the
log file is opened, so it is not buffered by `tee`.

`OVERWRITE_LFS` is **not** destructive: it re-pushes LFS objects and never
deletes existing OIDs.

---

## Verification

When `VERIFY=true`, each newly migrated repo is compared field-by-field
between GitHub and Gitea:

- Issues, PRs, releases, labels, milestones, branches, tags
- Wiki presence

GitHub counts come from a single GraphQL query; Gitea counts come from
`X-Total-Count` response headers. Mismatches are reported as warnings and
included in the final failure list. Unreadable counts (permission or API
errors) are tracked separately from true mismatches.

`VERIFY_ALL=true` additionally verifies pre-existing repos visited during a
`SYNC_EXISTING=git` pass.

---

## Output and logging

- All output is written to `migration-<timestamp>.log` (mode `0600`).
- A **comprehensive summary** is printed at the end, grouped by category
  (orgs, repos, webhooks, deploy keys, projects, gists, verification).
- A **per-item log** lists every migrated / skipped / failed entity.
- A **warnings section** surfaces degraded behavior (rate limits, missing
  permissions, partial verification).
- On any failure the script exits with code `1` and lists every failed item.

---

## Troubleshooting

| Symptom                                                | Likely cause / fix                                                                                            |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `GITHUB_USER does not match the authenticated account` | Fix `GITHUB_USER` in `.env` or issue a token for the correct account.                                         |
| `Gitea authentication failed`                          | Check `GITEA_TOKEN`; ensure it is a valid token for `GITEA_USER`.                                             |
| `Webhooks not readable (HTTP 403)`                     | GitHub token lacks `admin:repo_hook` / `admin:org_hook`, or admin rights on that repo/org.                    |
| `Projects not readable (GraphQL)`                      | Classic PAT lacks `read:project`.                                                                             |
| `Gitea has no usable projects API`                     | Upgrade Gitea to 28.4.0+ and enable the Projects unit.                                                        |
| `GITEA_USER differs from the authenticated account`    | Use a token for `GITEA_USER`, or set `MIGRATE_PROJECTS=false`.                                                |
| `ORG_VISIBILITY … conflicts with FORCE_PRIVATE`        | Set `ORG_VISIBILITY=private` or `auto`, or set `FORCE_PRIVATE=false`.                                         |
| `LFS sync skipped/failed`                              | `git-lfs` is not installed, or the repo doesn't use LFS. Set `OVERWRITE_LFS=true` to make LFS failures fatal. |
| Many `Repo Privacy` failures                           | Gitea token lacks permission to PATCH private visibility on the target owner.                                 |
| `Verification mismatch`                                | Repos migrated with some content missing — check `MIGRATE_*` flags and Gitea migration API logs.              |

---

## Exit codes

- `0` — Run completed with no recorded failures.
- `1` — Run completed but at least one item failed; see the `FAILED ITEMS`
  section of the summary.

---

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 Ahmed Ouda
