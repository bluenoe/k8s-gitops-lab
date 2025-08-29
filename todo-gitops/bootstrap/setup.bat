@echo off
REM Bootstrap script for Windows
setlocal enabledelayedexpansion

echo Starting k3d cluster bootstrap for TODO GitOps demo...

REM Configuration
set CLUSTER_NAME=todo-local
set ARGOCD_VERSION=v2.8.4
set SEALED_SECRETS_VERSION=v0.24.0
set REGISTRY_PORT=5001

REM Check dependencies
echo Checking dependencies...
where docker >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: Docker is not installed or not in PATH
    exit /b 1
)

where k3d >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: k3d is not installed or not in PATH
    exit /b 1
)

where kubectl >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: kubectl is not installed or not in PATH
    exit /b 1
)

where helm >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: helm is not installed or not in PATH
    exit /b 1
)

echo All dependencies are available

REM Delete existing cluster if exists
k3d cluster list | findstr %CLUSTER_NAME% >nul
if %ERRORLEVEL% equ 0 (
    echo Deleting existing cluster...
    k3d cluster delete %CLUSTER_NAME%
)

REM Create cluster
echo Creating k3d cluster: %CLUSTER_NAME%
k3d cluster create %CLUSTER_NAME% ^
    --api-port 6550 ^
    --servers 1 ^
    --agents 2 ^
    --port "8080:80@loadbalancer" ^
    --port "8443:443@loadbalancer" ^
    --registry-create "k3d-registry.localhost:%REGISTRY_PORT%" ^
    --k3s-arg "--disable=traefik@server:0" ^
    --wait

if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to create cluster
    exit /b 1
)

echo Cluster created successfully

REM Install Traefik
echo Installing Traefik...
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik ^
    --namespace traefik-system ^
    --create-namespace ^
    --set "ports.web.redirectTo=websecure" ^
    --set "ports.websecure.tls.enabled=true" ^
    --set "providers.kubernetesCRD.enabled=true" ^
    --set "providers.kubernetesIngress.enabled=true" ^
    --wait

REM Install ArgoCD
echo Installing ArgoCD...
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/%ARGOCD_VERSION%/manifests/install.yaml"

echo Waiting for ArgoCD to be ready...
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

REM Patch ArgoCD service to NodePort
kubectl patch svc argocd-server -n argocd -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"nodePort\":30080},{\"port\":443,\"nodePort\":30443}]}}"

REM Get ArgoCD password
for /f %%i in ('kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath^="{.data.password}"') do set ARGOCD_PASSWORD_B64=%%i
for /f %%i in ('echo %ARGOCD_PASSWORD_B64% ^| base64 -d') do set ARGOCD_PASSWORD=%%i

REM Install Sealed Secrets
echo Installing Sealed Secrets...
kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/%SEALED_SECRETS_VERSION%/controller.yaml"
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets-controller -n kube-system

REM Install Metrics Server
echo Installing Metrics Server...
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server ^
    --namespace kube-system ^
    --set args="{--cert-dir=/tmp,--secure-port=4443,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname,--kubelet-use-node-status-port,--metric-resolution=15s,--kubelet-insecure-tls}" ^
    --wait

REM Setup GitOps
echo Setting up GitOps applications...
timeout /t 30 /nobreak >nul
kubectl apply -f ../app-of-apps.yaml

echo.
echo ============================================
echo k3d cluster setup completed!
echo ============================================
echo.
echo Cluster Information:
echo   Cluster Name: %CLUSTER_NAME%
echo   Kubernetes API: https://localhost:6550
echo   Container Registry: k3d-registry.localhost:%REGISTRY_PORT%
echo.
echo Services:
echo   ArgoCD UI: https://localhost:30443
echo   ArgoCD Username: admin
echo   ArgoCD Password: %ARGOCD_PASSWORD%
echo.
echo Application URLs (after deployment):
echo   TODO App (Dev): http://todo-dev.local:8080
echo.
echo Please add the following to your hosts file (C:\Windows\System32\drivers\etc\hosts):
echo   127.0.0.1 todo-dev.local
echo   127.0.0.1 argocd.local
echo.
echo Useful Commands:
echo   kubectl get pods -A
echo   kubectl get applications -n argocd
echo   k3d cluster delete %CLUSTER_NAME%
echo.

pause