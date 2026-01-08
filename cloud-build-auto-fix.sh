
#!/usr/bin/env bash
# cloud-build-auto-fix.sh
# Validated script: lists builds, checks Dockerfile, enables required APIs,
# fetches and analyzes build logs, and can apply IAM fixes for Cloud Build SA.

set -euo pipefail

PROJECT=""
BUILD_ID=""
APPLY=0
YES=0
DRY=0

usage() {
  cat <<EOF
Usage: $0 [--project PROJECT] [--build BUILD_ID] [--enable-apis] [--apply] [--yes] [--dry-run]

Options:
  --project PROJECT     GCP project (defaults to gcloud config)
  --build BUILD_ID      Cloud Build ID to fetch logs for
  --enable-apis         Enable Security Command Center and Cloud Resource Manager APIs
  --apply               Apply recommended IAM bindings (requires --yes for non-interactive)
  --yes                 Non-interactive: accept prompts
  --dry-run             Show recommendations but don't apply changes
  -h, --help            Show this help

Examples:
  $0 --project my-project --build 936602bd-95dd-4be9-b020-60a6d0ada571 --enable-apis --apply --yes
EOF
}

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI not found. Run in Cloud Shell or install gcloud." >&2
  exit 2
fi

# simple arg parse
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --build) BUILD_ID="$2"; shift 2;;
    --enable-apis) ENABLE_APIS=1; shift;;
    --apply) APPLY=1; shift;;
    --yes) YES=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ -z "$PROJECT" ]; then
  echo "No project set. Use --project or run 'gcloud config set project PROJECT_ID'" >&2
  exit 1
fi

echo "Project: $PROJECT"

check_dockerfile() {
  echo "Checking for Dockerfile in current directory..."
  if [ -f Dockerfile ] || [ -f ./Dockerfile ]; then
    echo "OK: Dockerfile found. Suggested Build Configuration: Dockerfile or ./Dockerfile"
    return 0
  fi
  echo "WARNING: No Dockerfile found in current directory."
  return 1
}

enable_apis() {
  echo "Enabling Security Command Center and Cloud Resource Manager APIs for project $PROJECT"
  gcloud services enable securitycenter.googleapis.com cloudresourcemanager.googleapis.com --project="$PROJECT"
}

list_builds() {
  echo "Recent builds:"
  gcloud builds list --project="$PROJECT" --limit=5 --format="table(id,status,createTime,images)"
}

fetch_build_log() {
  local id="$1"
  if [ -z "$id" ]; then
    echo "No BUILD_ID provided."; return 1
  fi
  TMP_LOG="/tmp/cloudbuild-${id}.log"
  DESC_YAML="/tmp/cloudbuild-${id}.yaml"
  echo "Fetching build logs for $id..."
  gcloud builds log "$id" --project="$PROJECT" > "$TMP_LOG" || true
  gcloud builds describe "$id" --project="$PROJECT" --format=yaml > "$DESC_YAML" || true
  echo "Saved logs to: $TMP_LOG"
  echo "$TMP_LOG"
}

analyze_logs() {
  local logfile="$1"
  echo "Analyzing logs for common errors..."
  declare -a patterns=(
    "PERMISSION_DENIED" "PermissionDenied" "permission denied" "403" "Forbidden"
    "iam.serviceAccounts.getAccessToken" "does not have" "not authorized" "AccessDenied"
    "artifactregistry" "artifact registry" "Failed to push" "error building image" "docker build"
  )
  local found=0
  for p in "${patterns[@]}"; do
    if grep -i -n -m1 -- "$p" "$logfile" >/dev/null 2>&1; then
      echo "  - Detected: $p"
      found=1
    fi
  done
  return $found
}

recommend_roles() {
  local logfile="$1"
  local -a rec=()
  
  # Cloud Logging permissions (always recommended for Cloud Build)
  rec+=("roles/logging.logWriter")
  
  if grep -iq "artifactregistry" "$logfile" || grep -iq "artifact registry" "$logfile"; then
    rec+=("roles/artifactregistry.writer")
  fi
  if grep -iq "gcr.io" "$logfile" || grep -iq "storage" "$logfile"; then
    rec+=("roles/storage.admin")
  fi
  if grep -iq "cloud run" "$logfile" || grep -iq "Cloud Run" "$logfile"; then
    rec+=("roles/run.admin" "roles/iam.serviceAccountUser")
  fi
  if grep -iq "iam.serviceAccounts.getAccessToken" "$logfile" || grep -iq "does not have" "$logfile"; then
    rec+=("roles/iam.serviceAccountUser")
  fi
  # dedupe
  declare -A seen
  for r in "${rec[@]}"; do
    if [ -n "$r" ] && [ -z "${seen[$r]:-}" ]; then
      echo "$r"
      seen[$r]=1
    fi
  done
}

apply_iam_roles() {
  local -n roles_arr=$1
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  if [ -z "$PROJECT_NUMBER" ]; then
    echo "Unable to determine project number for $PROJECT" >&2; return 1
  fi
  SA="$PROJECT_NUMBER@cloudbuild.gserviceaccount.com"
  echo "Cloud Build service account: $SA"
  for role in "${roles_arr[@]}"; do
    echo "Applying $role to $SA..."
    if gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role="$role"; then
      echo "  - Added $role"
    else
      echo "  - Failed to add $role"
    fi
  done
}

# Run checks
check_dockerfile || true

if [ "${ENABLE_APIS:-0}" -eq 1 ] || [ "$YES" -eq 1 ]; then
  enable_apis
else
  echo "APIs not enabled (use --enable-apis or --yes to enable)."
fi

list_builds

if [ -n "$BUILD_ID" ]; then
  LOGFILE=$(fetch_build_log "$BUILD_ID")
  if analyze_logs "$LOGFILE"; then
    echo "Potential permission/artifact issues found. Recommended roles:"
    mapfile -t ROLE_LIST < <(recommend_roles "$LOGFILE")
    for r in "${ROLE_LIST[@]}"; do echo "  - $r"; done
    if [ ${#ROLE_LIST[@]} -gt 0 ]; then
      if [ "$DRY" -eq 1 ]; then
        echo "Dry-run: not applying roles.";
      else
        if [ "$APPLY" -eq 1 ]; then
          if [ "$YES" -eq 1 ]; then
            apply_iam_roles ROLE_LIST
          else
            read -r -p "Apply these roles to Cloud Build service account? [y/N] " ans
            case "$ans" in [Yy]*) apply_iam_roles ROLE_LIST;; *) echo "Aborted.";; esac
          fi
        else
          echo "To apply these roles, re-run with --apply (and --yes for non-interactive)."
        fi
      fi
    else
      echo "No IAM recommendations generated from heuristics."
    fi
  else
    echo "No obvious permission-related errors detected in the logs."
  fi
fi

echo "Done."

  
  PROJECT="${PROJECT:-$(get_project)}"
  [ -n "$PROJECT" ] || { echo "No project configured; use --project or 'gcloud config set project'"; exit 2; }
  
  echo "Project: $PROJECT"
  check_dockerfile || true
  if [ "$AUTO_YES" -eq 1 ]; then enable_apis "$PROJECT"; else echo "APIs not enabled (use --yes to enable)"; fi
  list_builds "$PROJECT"
  [ -n "$BUILD_ID" ] && fetch_build_log "$PROJECT" "$BUILD_ID"
  EOF
  
  # make executable and run (replace PROJECT_ID and BUILD_ID)
  chmod +x ~/cloud-build-auto-fix.sh
  ~/cloud-build-auto-fix.sh --project PROJECT_ID --yes --build BUILD_ID
else
  RETRY=1
fi

if [[ $RETRY -eq 1 ]]; then
  echo "Retrying build $BUILD_ID..."
  # This command may return new build details; we simply call retry and then tail logs
  NEW_BUILD_OUTPUT=$(gcloud builds retry "$BUILD_ID" --project="$PROJECT" 2>&1) || { echo "Failed to start retry: $NEW_BUILD_OUTPUT"; exit 1; }
  echo "$NEW_BUILD_OUTPUT"
  # Optionally, stream logs for a short time
  echo "Streaming logs (press Ctrl+C to stop)..."
  gcloud builds log --project="$PROJECT" --stream "$BUILD_ID" || true
  echo "Check Cloud Console for full logs and status."
fi

echo "Done. If build still fails, paste the failing log lines here and I will analyze further."
exit 0# make executable (Cloud Shell/WSL/Git Bash)
chmod +x scripts/cloud-build-auto-fix.sh

# show help
scripts/cloud-build-auto-fix.sh --help

# run: enable APIs and fetch logs for a build, non-interactive
scripts/cloud-build-auto-fix.sh --project PROJECT_ID --build BUILD_ID --enable-apis --apply --yescat > ~/cloud-build-auto-fix.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:-}"
BUILD_ID=""
ENABLE_APIS=0
APPLY=0
YES=0
DRY=0

usage(){ cat <<EOT
Usage: $0 --project PROJECT --build BUILD_ID [--enable-apis] [--apply] [--yes]
EOT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --build) BUILD_ID="$2"; shift 2;;
    --enable-apis) ENABLE_APIS=1; shift;;
    --apply) APPLY=1; shift;;
    --yes) YES=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found. Run this in Cloud Shell." >&2; exit 2
fi

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ -z "$PROJECT" ]; then echo "No project set; use --project"; exit 1; fi
echo "Project: $PROJECT"

check_dockerfile(){
  if [ -f Dockerfile ] || [ -f ./Dockerfile ]; then
    echo "Dockerfile found."
    return 0
  fi
  echo "No Dockerfile in current directory."
  return 1
}

enable_apis(){
  echo "Enabling APIs..."
  gcloud services enable securitycenter.googleapis.com cloudresourcemanager.googleapis.com --project="$PROJECT"
}

list_builds(){
  gcloud builds list --project="$PROJECT" --limit=5 --format="table(id,status,createTime,images)"
}

fetch_build_log(){
  local id="$1"
  TMP_LOG="/tmp/cloudbuild-${id}.log"
  gcloud builds log "$id" --project="$PROJECT" > "$TMP_LOG" || true
  echo "$TMP_LOG"
}

analyze_logs(){
  local f="$1"
  grep -i -E "permission|PERMISSION_DENIED|403|Forbidden|artifactregistry|Failed to push|error building image|iam.serviceAccounts.getAccessToken" "$f" || true
}

recommend_roles(){
  local f="$1"
  [ -n "$(grep -i artifactregistry "$f" || true)" ] && echo "roles/artifactregistry.writer"
  [ -n "$(grep -i gcr.io "$f" || true)" -o -n "$(grep -i storage "$f" || true)" ] && echo "roles/storage.admin"
  [ -n "$(grep -i 'cloud run' "$f" || true)" ] && echo "roles/run.admin" && echo "roles/iam.serviceAccountUser"
  [ -n "$(grep -i iam.serviceAccounts.getAccessToken "$f" || true)" ] && echo "roles/iam.serviceAccountUser"
}

apply_iam_roles(){
  local -n roles=$1
  PN=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  SA="${PN}@cloudbuild.gserviceaccount.com"
  for r in "${roles[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role="$r"
  done
}

# Run
check_dockerfile || true
[ "$ENABLE_APIS" -eq 1 ] && enable_apis || echo "APIs not enabled (pass --enable-apis)."
list_builds

if [ -n "$BUILD_ID" ]; then
  LOGFILE=$(fetch_build_log "$BUILD_ID")
  echo "Saved log at: $LOGFILE"
  analyze_logs "$LOGFILE"
  mapfile -t ROLES < <(recommend_roles "$LOGFILE")
  if [ ${#ROLES[@]} -gt 0 ]; then
    echo "Recommended roles: ${ROLES[*]}"
    if [ "$DRY" -eq 1 ]; then
      echo "Dry run; not applying."
    else
      if [ "$APPLY" -eq 1 ]; then
        if [ "$YES" -eq 1 ]; then
          apply_iam_roles ROLES
        else
          read -r -p "Apply roles? [y/N] " ans
          case "$ans" in [Yy]*) apply_iam_roles ROLES;; *) echo "Aborted";; esac
        fi
      else
        echo "To apply roles re-run with --apply."
      fi
    fi
  else
    echo "No IAM recommendations from heuristics."
  fi
else
  echo "No BUILD_ID provided."
fi

echo "Done."
EOF

chmod +x ~/cloud-build-auto-fix.sh