# Maintaining BasaltVR

This document describes how repository maintainers triage work, merge changes, update pinned
dependencies, and publish developer previews. It complements
[CONTRIBUTING.md](../CONTRIBUTING.md), which is written for contributors.

## Project model

BasaltVR is maintainer-led. Maintainers seek consensus for normal changes and document important
compatibility, protocol, licensing, or security decisions in the relevant architecture document
or pull request. The current narrow product and safety boundaries take precedence over expanding
feature scope.

Maintainers are expected to:

- enforce the [Code of Conduct](../CODE_OF_CONDUCT.md) and security policy;
- keep `main` buildable and require the relevant automated checks before merge;
- distinguish deterministic test evidence from live-headset observations;
- preserve the clean-room and third-party distribution boundaries;
- avoid making compatibility claims that are not backed by a recorded environment and test.

## Issue triage

For each new issue:

1. Confirm that it contains a version, environment, reproduction, expected result, and sanitized
   diagnostics.
2. Redirect private security material to GitHub private vulnerability reporting and remove public
   sensitive data as quickly as possible.
3. Reproduce locally when possible. Mark hardware-only results explicitly.
4. Apply one type label (`bug`, `enhancement`, `question`, or `compatibility`) and an area label
   (`manager`, `streamer`, `runtime`, `bottles`, `packaging`, or `documentation`).
5. Close duplicates with a link to the canonical issue. Close out-of-scope requests with a brief
   explanation and a link to [ROADMAP.md](../ROADMAP.md) where applicable.

Good first issues should be independently testable, have an agreed outcome, and avoid requiring
private hardware or accounts. Do not use that label for unresolved architecture work.

## Pull requests

Pull requests should be focused, explain the user-visible problem, and include tests for changed
behavior. Before merge:

- `make check` passes;
- the runtime or DXMT gate passes when that subsystem changes;
- documentation and release notes reflect user-visible behavior;
- protocol or persisted-data changes describe compatibility and rollback;
- generated files, local prefixes, credentials, device IDs, and private logs are absent;
- at least one maintainer has reviewed the final diff when more than one maintainer is available.

Use squash merge for a small single-purpose change and preserve separate commits when their
history materially helps review or future bisection. Never rewrite a contributor's branch without
their consent.

## Labels and milestones

Create these labels when the GitHub repository is initialized:

| Group | Labels |
|---|---|
| Type | `bug`, `enhancement`, `question`, `compatibility`, `security` |
| Area | `manager`, `streamer`, `runtime`, `bottles`, `packaging`, `documentation` |
| Status | `needs-reproduction`, `needs-hardware`, `blocked`, `good first issue`, `help wanted` |
| Automation | `dependencies` |

Milestones should represent a release or a verifiable product gate, not an open-ended component
backlog.

## Pinned dependencies

Wine, DXMT, LLVM, OpenXR, and ALVR protocol assumptions are compatibility boundaries rather than
ordinary floating dependencies. An update must:

1. record the old and new versions, source URLs, commits, hashes, and licenses;
2. update all pins and third-party notices together;
3. rebuild from an empty ignored build directory;
4. pass the deterministic Wine/DXMT suites;
5. repeat the relevant live-headset gate before changing a compatibility claim.

GitHub Actions updates are proposed by Dependabot. Workflow actions remain pinned to immutable
full commit SHAs; keep the human-readable release tag in a comment.

## Releases

Follow [docs/RELEASING.md](RELEASING.md). Release artifacts must come from the tag's workflow,
not from a developer's ignored local build directory. If a release is withdrawn, keep a short
public explanation and point users to the fixed version rather than silently replacing history.

## Repository settings

After creating the public GitHub repository:

- protect `main` and require the CI quality and runtime jobs;
- require pull requests and dismiss stale approvals after material changes;
- enable private vulnerability reporting, Dependabot alerts, secret scanning, and push
  protection;
- restrict workflow token permissions by default and allow write access only in the release
  workflow;
- enable Discussions if maintainers want to separate open-ended setup conversations from
  actionable issues;
- periodically review collaborators, branch rules, deploy keys, environments, and stale secrets.

## Adding maintainers

Sustained reviewers who demonstrate sound technical judgment, respect the project's safety and
licensing boundaries, and participate constructively may be invited as maintainers. Repository
administration and release access should be held by at least two trusted people once the project
has a stable contributor base. Access must be removed promptly when a maintainer steps down.
