#!/usr/bin/env bash
set -euo pipefail

# cloud-build-revert-iam.sh
# Usage:
#   ./cloud-build-revert-iam.sh -f /path/to/applied-roles-file [-p PROJECT] [--dry-run] [--yes]
# The applied-roles file is created by cloud-build-auto-fix.sh and contains the roles that were added.

APPLIED_FILE=""
PROJECT=""
YES=0
DRY=0

usage() {
  cat <<EOF
Usage: $0 -f /path/to/applied-roles-file [-p PROJECT] [--dry-run] [--yes]

Options:
  -f, --file FILE         The applied-roles file (required)
  -p, --project PROJECT   GCP project (default: gcloud config project)
      --dry-run           Show the removals that would happen without applying them
      --yes               Non-interactive: assume yes for confirmations
      --help              Show this help

Example:
  ./cloud-build-revert-iam.sh -f /tmp/applied-roles-9366...txt --dry-run

This script will:
  - Parse the applied roles file to find the service account and roles added
  - Optionally remove those roles from the service account (with confirmation)
  - Log all operations to /tmp/reverted-roles-<timestamp>.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -f|--file) APPLIED_FILE="$2"; shift 2 ;; 
    -p|--project) PROJECT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$APPLIED_FILE" ]]; then
  echo "Error: applied roles file is required." >&2
  usage
  exit 1
fi

if [[ ! -f "$APPLIED_FILE" ]]; then
  echo "Error: file $APPLIED_FILE not found." >&2
  exit 1
fi

if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
fi
if [[ -z "$PROJECT" ]]; then
  echo "Error: No project set. Use -p or run 'gcloud config set project PROJECT_ID'" >&2
  exit 1
fi

# Read service account from the file (look for a line containing '@cloudbuild.gserviceaccount.com')
SA_LINE=$(grep -m1 -E "@cloudbuild.gserviceaccount.com" "$APPLIED_FILE" || true)
if [[ -z "$SA_LINE" ]]; then
  echo "Error: could not find cloudbuild service account in $APPLIED_FILE" >&2
  exit 1
fi

CLOUDBUILD_SA=$(echo "$SA_LINE" | grep -oE "[0-9]+@cloudbuild.gserviceaccount.com" || true)
if [[ -z "$CLOUDBUILD_SA" ]]; then
  echo "Error: could not parse service account from line: $SA_LINE" >&2
  exit 1
fi

# Parse roles from the file: look for lines that look like roles/...
mapfile -t ROLES < <(grep -Eo "roles/[a-zA-Z0-9_.-]+" "$APPLIED_FILE" | sort -u)
if [[ ${#ROLES[@]} -eq 0 ]]; then
  echo "Error: no roles found in $APPLIED_FILE" >&2
  exit 1
fi

echo "Project: $PROJECT"
echo "Service account: $CLOUDBUILD_SA"
echo "Roles to remove: ${ROLES[*]}"

if [[ $DRY -eq 1 ]]; then
  echo "Dry run: not modifying IAM."
  exit 0
fi

if [[ $YES -eq 0 ]]; then
  read -r -p "Remove the above roles from $CLOUDBUILD_SA in project $PROJECT? [y/N]: " ans
  case "$ans" in
    [yY]|[yY][eE][sS]) true ;;
    *) echo "Aborted by user."; exit 0 ;;
  esac
fi

LOG_FILE="/tmp/reverted-roles-$(date +%Y%m%d%H%M%S).txt"
echo "Reverting roles for $CLOUDBUILD_SA on $(date)" > "$LOG_FILE"
echo "Project: $PROJECT" >> "$LOG_FILE"

echo "Starting removals..." | tee -a "$LOG_FILE"
for role in "${ROLES[@]}"; do
  echo "Processing $role..." | tee -a "$LOG_FILE"
  # Check if binding exists
  bound=$(gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[]" --filter="bindings.role=$role AND bindings.members:serviceAccount:$CLOUDBUILD_SA" --format='value(bindings.role)' 2>/dev/null || true)
  if [[ -z "$bound" ]]; then
    echo "  - $role not currently bound to $CLOUDBUILD_SA; skipping." | tee -a "$LOG_FILE"
    continue
  fi

  if gcloud projects remove-iam-policy-binding "$PROJECT" --member="serviceAccount:$CLOUDBUILD_SA" --role="$role" >>"$LOG_FILE" 2>&1; then
    echo "  - Removed $role" | tee -a "$LOG_FILE"
  else
    echo "  - Failed to remove $role (see above)" | tee -a "$LOG_FILE"
  fi
done

echo "Reversion complete. See log: $LOG_FILE" | tee -a "$LOG_FILE"
exit 0
