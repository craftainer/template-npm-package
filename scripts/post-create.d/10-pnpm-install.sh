#!/usr/bin/env bash
# Installs the package's dependencies into node_modules, which the prek hooks
# (oxlint/prettier/tsc/vitest/tsdown/publint/attw) all run from.
set -euo pipefail

cd /workspace
pnpm install --frozen-lockfile
