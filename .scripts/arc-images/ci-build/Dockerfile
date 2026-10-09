# ci-build: the default JOB CONTAINER image for the ARC scale set arc-ceres (#340).
# Built and pushed by ../build.sh to harbor.lab.local/actions/ci-build:<VERSION>.
# Docs: landingzones/arc-runners/README.md ("Job image", "Adding a toolchain").
#
# ARC runs in kubernetes mode: every job declares `container:` and its steps run
# in a pod created from that image, not in the runner. So toolchains live HERE
# (or in another job image), not in the runner image.
#
# What a job container needs, and why this image has it:
# - glibc + libstdc++: JavaScript actions (actions/checkout, …) run with the
#   runner's own node (externals/node20|node24, glibc builds), which the hook
#   copies onto the work volume and mounts at /__e. No node in the image.
#   Alpine/musl would need the *_alpine node builds; avoid.
# - /bin/sh: run steps are exec'd as `sh -e <script>`.
# - git, curl, jq, ca-certificates: checkout, Harbor API calls.
# - uid 1001 / gid 123, the runner's ids: files on the shared RWX work volume
#   stay writable by both. Non-root.
# The lab CA and the Harbor push credential are NOT baked in: the hook template
# mounts them (/etc/lab-ca/ca.crt, /kaniko/.docker/config.json) at run time.
# Image builds do NOT happen in this container: they run as a separate
# `uses: docker://harbor.lab.local/actions/kaniko:…` step pod (README).

# Base comes through the Harbor proxy cache (dockerhub), pinned by the upstream
# index digest (Harbor serves the same digest). Bump: README "Bumping".
ARG BASE=harbor.lab.local/dockerhub/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
FROM ${BASE}

ARG VERSION=dev

# --- base tools (keep this list short; toolchains go in their own layer) ---
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      jq \
      libstdc++6 \
      tar \
      gzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# --- toolchains (see README "Adding a toolchain") ---
# Example: Python for ceres tests (pip packages still need a PyPI mirror in an
# airgap; out of scope for #340):
# RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv \
#  && rm -rf /var/lib/apt/lists/*

# The runner's uid/gid (actions-runner image: runner 1001, docker group 123).
# The workspace sits on the shared work volume; safe.directory lets git work
# there whoever created the directory (actions/checkout also sets it itself).
RUN groupadd --gid 123 ci \
 && useradd --uid 1001 --gid 123 --create-home --home-dir /home/runner --shell /bin/bash runner \
 && git config --system --add safe.directory '*'

# No apostrophes inside LABEL values: kaniko's word parser rejects them
# ("unexpected end of statement while looking for matching single-quote").
LABEL org.opencontainers.image.title="ci-build" \
      org.opencontainers.image.description="ARC kubernetes-mode job container (git, curl, jq; glibc for the runner node)" \
      org.opencontainers.image.source="https://github.com/jellebens/gitops/tree/master/.scripts/arc-images/ci-build" \
      org.opencontainers.image.version="${VERSION}"

USER 1001:123
WORKDIR /home/runner
