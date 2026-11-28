---
id: CHR-OPS-001
status: draft            # draft | proposed | accepted | superseded | deprecated
authors: [the praetor]
date: 2026-11-28
supersedes:
superseded_by:
---

# CHR-OPS-001: gitops charter

## Purpose

This repository is the desired state of the lab's k3s cluster. Argo CD
reads it and makes the cluster equal to it: one `bootstrap` Application
installs the app-of-apps layer in `applications/`. That layer installs the
platform services (`platform/`), the Argo CD projects (`projects/`) and the
workloads (`landingzones/`), each a Helm chart, with the values in
`.config/`. Argo CD deploys from `master` alone.

The cluster runs the household's services: the battery optimiser, the
hydroponics control, the observability stack, Harbor as the registry on the
LAN, and Legion itself. A change to the cluster is a change to this
repository. Nothing is applied by hand.

The repository is enlisted in Legion so that its work can be planned as
work packages and done by agents, each in a fabrica of its own, under the
praetor's review.

## Objectives

| Id | Objective | Success criterion | Measured by | Target |
| --- | --- | --- | --- | --- |
| OBJ-01 | The cluster equals this repository | every Application is Synced and Healthy on the commit at the head of `master`; no resource is changed by hand | `argocd app list --core` | `<to set by the praetor>` |
| OBJ-02 | Every change reaches the cluster through review | every change lands in `develop` by a pull request and reaches `master` only through a release pull request the praetor merges | the pull-request history | `<to set by the praetor>` |
| OBJ-03 | The services the household relies on stay up | `<to set by the praetor>` | `<to set by the praetor>` | `<to set by the praetor>` |

## Scope

### In scope

- The Argo CD bootstrap, the app-of-apps layer and the AppProjects.
- The charts and values of the platform services, among them the gateway,
  certificates, DNS, storage, observability, policy and the registry.
- The landing zones of the workloads that run on the cluster, Legion's
  among them.
- Sealed secrets, which are sealed for the cluster and never held in plain
  text.
- The agents' definitions, skills and guardrails in `.claude/` and
  `.github/`, and the repository's documents in `docs/`.

### Out of scope

- The nodes, k3s itself, the CNI and Argo CD's own installation. These are
  set up by the homelab repository, which Argo CD comes up after.
- The code and the images of the workloads. They live in their own
  repositories and are built there. This repository names their versions.
- Flux and Kustomize. Argo CD and Helm are the stack.

## Roles and decision rights

| Role | Who | Responsibilities |
| --- | --- | --- |
| Praetor | the owner of the cluster | defines and shapes the repository; accepts documents and work; merges into `develop` and releases to `master` |
| Operator | the same person | runs the cluster, holds the keys of the sealed secrets off the cluster |
| Engineers | agents, each alone in its fabrica | implement one work package on a branch of its own; open one pull request into `develop` |
| Reviewer | the praetor | reviews every pull request |

| Decision | Decided by | Recorded in |
| --- | --- | --- |
| Accept a charter or another document | the praetor | the pull request; the document's `status` |
| Accept work | the praetor | the pull request into `develop`, merged |
| Deploy | the praetor | the release pull request from `develop` into `master`, merged |
| Change scope, objectives or budget | the praetor | this charter's revision history |

Agents make none of these decisions.

## Constraints

| Id | Constraint | Source |
| --- | --- | --- |
| CON-01 | Argo CD and Helm only; Flux and Kustomize are not used | `CLAUDE.md`, Stack |
| CON-02 | Argo CD deploys from `master`; work branches off `develop` and returns to it by a pull request; only a release pull request reaches `master`; nothing is committed to `develop` or `master` directly | `AGENTS.md`, Branching & Release Flow |
| CON-03 | Container images are built for `linux/arm64`, since every node of the cluster is arm64 | `CLAUDE.md`, Environment & shell |
| CON-04 | Secrets are SealedSecrets; the controller's private keys are held off the cluster and never exported in an agent's session | `CLAUDE.md`, Secrets |
| CON-05 | Commits follow Conventional Commits, `type(scope): subject` | `AGENTS.md`, Conventions To Preserve |
| CON-06 | Images and charts come from Harbor on the LAN where the repository says so | `applications/templates/arc/arc-app.yaml`; `docs/arc-mirror.md`; `landingzones/legion` |

## Assumptions

| Id | Assumption | If false |
| --- | --- | --- |
| ASM-01 | One person is both the praetor and the operator of the cluster | the roles and decision rights are revisited |
| ASM-02 | The cluster is on a trusted home network, and its services are not published on the internet unless a landing zone says so | the gateway and its exposure become a requirement of their own |

## Budget

| Item | Cap | Alert at | Period |
| --- | --- | --- | --- |
| Agent spend (USD) | `<to set by the praetor>` | `<to set by the praetor>` | month |
| Infrastructure | the lab cluster: `<to set by the praetor>` | | |
| People | the praetor's time: `<to set by the praetor>` | | |

## Risks

| Id | Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- | --- |
| RSK-01 | A merge into `master` deploys at once, so a bad change takes a live service down, the battery optimiser among them | medium | high | a release pull request the praetor merges; a render with `helm template` before every commit |
| RSK-02 | An agent's session leaks a secret, or a sealed-secret key | low | high | secrets sealed for the cluster only; the keys never exported in an agent's session; the command-approval hook |
| RSK-03 | An agent's fabrica changes the cluster directly, outside this repository | low | high | engineers work on a branch and open a pull request; the cluster is changed by Argo CD alone |

## Revision history

| Version | Date | Change | By |
| --- | --- | --- | --- |
| 0.1 | 2026-11-28 | first draft, from the repository's own description in `CLAUDE.md` and `AGENTS.md`, to enlist the repository in Legion | drafted by an agent for the praetor to correct |
