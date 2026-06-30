#!/bin/bash

set -euo pipefail
helmfile --kubeconfig ~/.kube/clusters/pet-project-cluster.yaml $@