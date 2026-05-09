#!/bin/bash
set -euo pipefail

certname="${PT_certname}"

if ! command -v puppetserver >/dev/null 2>&1; then
  printf '{"status":"not_installed","error":"puppetserver not installed"}\n'
  exit 0
fi

puppetserver ca sign --certname "$certname" >&2
printf '{"status":"signed","certname":"%s"}\n' "$certname"
