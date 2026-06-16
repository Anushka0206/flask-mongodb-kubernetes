# Flask + MongoDB on Minikube — Windows deploy helper
# Run from the project/ folder:  .\deploy.ps1

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "FAIL $msg" -ForegroundColor Red; exit 1 }

$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path "$ProjectRoot\k8s")) {
    Write-Fail "k8s/ not found. Run this script from the project folder:`n  cd `"$ProjectRoot`"`n  .\deploy.ps1"
}

Write-Step "Checking Docker"
try {
    docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker not ready" }
    Write-Ok "Docker is running"
} catch {
    Write-Fail @"
Docker is not running.

1. Open Docker Desktop from the Start menu
2. Wait until it shows "Docker Desktop is running"
3. Run this script again
"@
}

Write-Step "Checking Minikube"
$minikubeCmd = Get-Command minikube -ErrorAction SilentlyContinue
if (-not $minikubeCmd) {
    $defaultMinikube = "C:\Program Files\Kubernetes\Minikube\minikube.exe"
    if (Test-Path $defaultMinikube) {
        $minikubeDir = Split-Path $defaultMinikube -Parent
        $env:Path = "$env:Path;$minikubeDir"
        $minikubeCmd = Get-Command minikube -ErrorAction SilentlyContinue
    }
}
if (-not $minikubeCmd) {
    Write-Fail @"
Minikube is not installed.

Install it (PowerShell as Administrator):

  winget install Kubernetes.minikube

Close and reopen PowerShell. If still not found, add to PATH:

  [Environment]::SetEnvironmentVariable("Path", `$env:Path + ";C:\Program Files\Kubernetes\Minikube", "User")

Then run this script again.
"@
}
Write-Ok "Minikube is installed ($((minikube version --short 2>$null)))"

Write-Step "Checking kubectl cluster"
$ctx = kubectl config current-context 2>$null
if (-not $ctx -or $ctx -notmatch "minikube") {
    Write-Host "No Minikube cluster detected. Starting Minikube (first run may take several minutes)..." -ForegroundColor Yellow
    minikube start --cpus=4 --memory=6144 --driver=docker
    if ($LASTEXITCODE -ne 0) { Write-Fail "minikube start failed" }
}
Write-Ok "Kubernetes cluster is available ($((kubectl config current-context)))"

Write-Step "Enabling Minikube addons"
minikube addons enable metrics-server | Out-Null
Write-Ok "metrics-server enabled"

Write-Step "Pointing Docker to Minikube daemon"
& minikube -p minikube docker-env --shell powershell | Invoke-Expression
Write-Ok "Docker environment set to Minikube"

Write-Step "Building Flask image"
docker build -t flask-app:latest .
if ($LASTEXITCODE -ne 0) { Write-Fail "docker build failed" }
Write-Ok "Image flask-app:latest built"

Write-Step "Deploying Kubernetes manifests"
kubectl apply -f k8s/
if ($LASTEXITCODE -ne 0) { Write-Fail "kubectl apply failed" }
Write-Ok "Manifests applied"

Write-Step "Waiting for workloads"
kubectl rollout status statefulset/mongo --timeout=180s
kubectl rollout status deployment/flask-app --timeout=180s
kubectl wait --for=condition=ready pod -l app=mongo --timeout=180s
kubectl wait --for=condition=ready pod -l app=flask --timeout=180s

$ip = minikube ip
$url = "http://${ip}:30080"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Deployment complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Flask URL: $url"
Write-Host "`nTest commands:"
Write-Host "  curl $url/"
Write-Host "  curl -X POST $url/data -H `"Content-Type: application/json`" -d '{`"name`":`"test`"}'"
Write-Host "  curl $url/data"
Write-Host "`nOr open in browser:"
Write-Host "  minikube service flask-service --url"
