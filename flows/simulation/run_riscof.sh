#!/bin/bash
# Run RISCOF regression
set -e
cd "$(dirname "$0")"
make riscof_run
