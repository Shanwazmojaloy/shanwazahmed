# run-auto-fix.ps1
<#
PowerShell wrapper to run the auto-fix script non-interactively and collect outputs.
Usage:
  pwsh ./scripts/run-auto-fix.ps1 -BuildId 936602bd-95dd-4be9-b020-60a6d0ada571

This script assumes you have access to bash (Cloud Shell, WSL, Git-Bash) and gcloud configured.
#>
param(
  [string]$BuildId = "936602bd-95dd-4be9-b020-60a6d0ada571",
  [switch]$NoStream
)

$scriptPath = "./scripts/cloud-build-auto-fix.sh"
if (-not (Test-Path $scriptPath)) {
  Write-Error "Auto-fix script not found at $scriptPath"
  exit 1
}

# Use bash to run the existing script (ensures consistent behavior across environments)
$cmd = "chmod +x $scriptPath && $scriptPath -b $BuildId --apply --yes 2>&1 | tee cloud-build-auto-fix-output.txt"
Write-Host "Running auto-fix for build $BuildId..." -ForegroundColor Cyan
bash -lc $cmd

Write-Host "\n--- Top of cloud-build-auto-fix-output.txt ---" -ForegroundColor Green
bash -lc "head -n 200 cloud-build-auto-fix-output.txt || true"

Write-Host "\n--- Audit files in /tmp ---" -ForegroundColor Green
bash -lc "ls -1 /tmp/applied-roles-*.txt || true"

# Print the first audit file if any
$applied = bash -lc "ls -1 /tmp/applied-roles-*.txt 2>/dev/null | head -n1 || true" | Out-String
$applied = $applied.Trim()
if ($applied) {
  Write-Host "\n--- Contents of $applied ---" -ForegroundColor Yellow
  bash -lc "cat $applied || true"
} else {
  Write-Host "No audit file found in /tmp." -ForegroundColor Yellow
}

if (-not $NoStream) {
  Write-Host "\n--- Streaming build logs (press CTRL+C to stop) ---" -ForegroundColor Cyan
  bash -lc "gcloud builds log $BuildId --project=$(gcloud config get-value project) --stream || true"
}

Write-Host "\nDone. Paste the top section of cloud-build-auto-fix-output.txt and the contents of /tmp/applied-roles-*.txt here so I can verify." -ForegroundColor Magenta
