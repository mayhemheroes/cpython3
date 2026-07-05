# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for mayhemheroes/cpython3.
# Builds CPython with ASan+UBSan, then compiles each OSS-Fuzz harness from
# Modules/_xxtestfuzz/ as a libFuzzer target (+ standalone reproducer) and
# a KAT oracle for the test suite.
#
# Build (from the repo root on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       -t cpython3-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake as ENV —
# an empty value breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS; declare without default
# so unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Install CPython build dependencies.
# Using --no-install-recommends and a single layer to keep the image lean.
# All packages are pinned to what apt resolves — air-gapped re-runs of build.sh
# don't need the network (make is incremental; configure has its results cached).
USER root
RUN apt-get update && apt-get install -yq --no-install-recommends \
      build-essential \
      libncursesw5-dev \
      libreadline-dev \
      libssl-dev \
      libgdbm-dev \
      libc6-dev \
      libsqlite3-dev \
      libbz2-dev \
      zlib1g-dev \
      libffi-dev \
      libexpat1-dev \
      pkg-config \
      zip \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl.
# .git history) is copied to /mayhem; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the functional KAT oracle at build time (a failing suite fails the image).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
