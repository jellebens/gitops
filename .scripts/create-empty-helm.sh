#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./create-empty-helm-chart.sh <chart-name> [destination-directory]
#
# Example:
#   ./create-empty-helm-chart.sh bootstrap ./charts

CHART_NAME="${1:-}"
DEST_DIR="${2:-.}"

if [[ -z "${CHART_NAME}" ]]; then
  echo "Usage: $0 <chart-name> [destination-directory]"
  exit 1
fi

CHART_DIR="${DEST_DIR}/${CHART_NAME}"

if [[ -e "${CHART_DIR}" ]]; then
  echo "Error: ${CHART_DIR} already exists"
  exit 1
fi

mkdir -p "${CHART_DIR}/templates"

cat > "${CHART_DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: ${CHART_NAME}
description: Empty Helm chart for ${CHART_NAME}
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > "${CHART_DIR}/values.yaml" <<EOF
# Default values for ${CHART_NAME}
EOF

cat > "${CHART_DIR}/.helmignore" <<'EOF'
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
EOF

touch "${CHART_DIR}/templates/.gitkeep"

echo "Empty Helm chart created at: ${CHART_DIR}"