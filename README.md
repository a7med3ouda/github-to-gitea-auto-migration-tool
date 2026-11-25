# github-to-gitea-auto-migration-tool

A single-script, configuration-driven tool that migrates a GitHub account
(personal repositories, organization repositories, gists, webhooks, deploy
keys, and GitHub Projects v2 boards) into a self-hosted Gitea instance.

The script is written in bash and depends only on `curl`, `jq`, and
(optionally) `git` / `git-lfs`.

---

## Table of contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Required variables](#required-variables)
  - [Migration flags](#migration-flags)
  - [Overwrite flags](#overwrite-flags)
  - [Behavior flags](#behavior-flags)
  - [Token scopes](#token-scopes)
- [Usage](#usage)
- [What gets migrated](#what-gets-migrated)
- [What does _not_ get migrated](#what-does-not-get-migrated)
- [Destructive operations](#destructive-operations)
- [Verification](#verification)
- [Output and logging](#output-and-logging)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

`run.sh` reads a `.env` file, authenticates against GitHub and Gitea, and
walks your account (and any organizations you belong to) migrating
repositories, webhooks, deploy keys, gists, and Projects v2 boards.

The tool is designed to be **safe by default**:

- Existing Gitea repositories are **skipped** unless `SYNC_EXISTING=git`.
- Destructive `OVERWRITE_*` flags are **off** unless explicitly enabled and
  confirmed (either interactively by typing `DELETE`, or via `--yes`).
- A `--dry-run` mode reads everything but never writes to Gitea.

---

## Features

- **Full repository migration** via Gitea's `/api/v1/repos/migrate` endpoint,
  including issues, pull requests, releases, labels, milestones, and wiki.
- **Organization migration** with optional overwrite (deletes and recreates the
  org, its repos, and its webhooks).
- **Gist migration** as private/public Gitea repositories, with secret gists
  kept private.
- **Webhook migration** (repo-level and org-level) with GitHub → Gitea event
  mapping; unsupported events are skipped with a warning rather than mapped
  incorrectly.
- **Deploy key migration** with read-only flag preserved.
- **GitHub Projects v2 → Gitea project boards**, using a configurable
  single-select field (`PROJECTS_STATUS_FIELD`) as board columns. A
  `No Status` column is added for items without a value.
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
- Gitea **28.0+** with the Projects unit enabled (only for project migration)

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

If any destructive `OVERWRITE_*` flag is enabled or `SYNC_EXISTING=git`, you
will be asked to type `DELETE` to confirm. In a non-interactive shell, pass
`--yes` (or set `ASSUME_YES=true`).

---

## Configuration

All configuration lives in `.env` in the current directory (override with
`ENV_FILE=/path/to/file`).

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
the Gitea side.

| Variable                 | Effect                                                   |
| ------------------------ | -------------------------------------------------------- |
| `OVERWRITE_REPOS`        | Delete and re-migrate existing repos.                    |
| `OVERWRITE_ORGS`         | Delete the org and all its repos, then recreate.         |
| `OVERWRITE_GISTS`        | Delete and re-migrate existing gist repos.               |
| `OVERWRITE_PROJECTS`     | Delete and recreate marked project boards.               |
| `OVERWRITE_WEBHOOKS`     | Delete and recreate repo webhooks.                       |
| `OVERWRITE_ORG_WEBHOOKS` | Delete and recreate org webhooks.                        |
| `OVERWRITE_DEPLOY_KEYS`  | Delete and recreate deploy keys.                         |
| `OVERWRITE_LFS`          | Re-fetch and push **all** LFS objects (deletes nothing). |

### Behavior flags

| Variable                | Default                     | Purpose                                                                          |
| ----------------------- | --------------------------- | -------------------------------------------------------------------------------- |
| `MAKE_PRIVATE`          | `true`                      | Force destination repos/gists/orgs private. Private sources always stay private. |
| `ALLOW_INSECURE_HTTP`   | `false`                     | Permit plain HTTP to Gitea.                                                      |
| `SYNC_EXISTING`         | `skip`                      | `skip` or `git` (force-update branches/tags, prune refs).                        |
| `VERIFY`                | `true`                      | Verify migrated repos after creation.                                            |
| `VERIFY_ALL`            | `false`                     | Also verify pre-existing repos during `SYNC_EXISTING`.                           |
| `HOOKS_CREATE_INACTIVE` | `true`                      | Create webhooks as inactive on Gitea.                                            |
| `GITHUB_AFFILIATION`    | `owner`                     | `owner`, `collaborator`, or `owner,collaborator`.                                |
| `GH_MAX_WAIT`           | `3700`                      | Max seconds to sleep for a GitHub rate-limit reset.                              |
| `PROJECTS_STATUS_FIELD` | `Status`                    | Single-select field used as board columns.                                       |
| `DRY_RUN`               | `false`                     | Same as `--dry-run`.                                                             |
| `ASSUME_YES`            | `false`                     | Same as `--yes`.                                                                 |
| `LOG_FILE`              | `migration-<timestamp>.log` | Log file path.                                                                   |

### Token scopes

**GitHub classic PAT** should include:

- `repo` — repositories, issues, PRs, webhooks, deploy keys
- `read:org` — organization listings and org webhooks
- `read:project` — Projects v2 boards
- `gist` — gist migration

**Gitea token** must allow creating repos/orgs, managing webhooks and deploy
keys, and managing projects. If you migrate projects and `GITEA_USER` differs
from the token account, the script will refuse to run (unless projects are
disabled).

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

---

## What gets migrated

- Personal repos (filters via `GITHUB_AFFILIATION`)
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

In an interactive shell you must type `DELETE`. In a non-interactive shell you
must pass `--yes` / `ASSUME_YES=true`.

`OVERWRITE_LFS` is **not** destructive (it re-pushes LFS objects and never
deletes existing OIDs).

---

## Verification

When `VERIFY=true`, each newly migrated repo is compared field-by-field
between GitHub and Gitea:

- Issues, PRs, releases, labels, milestones, branches, tags
- Wiki presence

GitHub counts come from a single GraphQL query; Gitea counts come from
`X-Total-Count` response headers. Mismatches are reported as warnings and
included in the final failure list.

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
| `Webhooks not readable (HTTP 403)`                     | GitHub token lacks `repo` (or `read:org`) hook-admin scope.                                                   |
| `Projects not readable (GraphQL)`                      | Classic PAT lacks `read:project`.                                                                             |
| `Gitea has no usable projects API`                     | Upgrade Gitea to 28.0+ and enable the Projects unit.                                                          |
| `LFS sync skipped/failed`                              | `git-lfs` is not installed, or the repo doesn't use LFS. Set `OVERWRITE_LFS=true` to make LFS failures fatal. |
| Many `Repo Privacy` failures                           | Gitea token lacks permission to PATCH private visibility on the target owner.                                 |
| `Verification mismatch`                                | Repos migrated with some content missing — check `MIGRATE_*` flags and Gitea migration API logs.              |

---

## License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 Ahmed Ouda
