#!/usr/bin/env bash
# Executes the hub's Seagit config (values.yaml jupyterhub.hub.extraConfig.seagit) in the real hub
# image for all three sign-in modes. Needs docker. Run from the repo root.
set -euo pipefail
chart=charts/sg-notebooks
img=quay.io/jupyterhub/k8s-hub:$(awk '/name: jupyterhub/{f=1} f&&/version:/{print $2; exit}' "$chart/Chart.yaml")
docker run --rm -v "$PWD/$chart:/chart:ro" --entrypoint python "$img" /chart/tests/config_test.py /chart/values.yaml
