#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="todo-local"
ARGOCD_VERSION="v2.8.4"
SEALED_SECRETS_VERSION="v0.24.0"
REGISTRY_PORT="5001"

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠ $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1${NC}"
    exit 1
}

check_dependencies() {
    log "Checking dependencies..."
    
    commands=("docker" "k3d" "kubectl" "helm")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "$cmd is not installed. Please install it first."
        else
            success "$cmd is available"
        fi
    done
}

create_cluster() {
    log "Creating k3d cluster: $CLUSTER_NAME"
    
    if k3d cluster list | grep -q "$CLUSTER_NAME"; then
        warning "Cluster $CLUSTER_NAME already exists. Deleting..."
        k3d cluster delete "$CLUSTER_NAME"
    fi
    
    # Create cluster with registry and load balancer
    k3d cluster create "$CLUSTER_NAME" \
        --api-port 6550 \
        --servers 1 \
        --agents 2 \
        --port "8080:80@loadbalancer" \
        --port "8443:443@loadbalancer" \
        --registry-create "k3d-registry.localhost:$REGISTRY_PORT" \
        --k3s-arg "--disable=traefik@server:0" \
        --wait
    
    success "Cluster $CLUSTER_NAME created successfully"
}

install_traefik() {
    log "Installing Traefik ingress controller..."
    
    helm repo add traefik https://traefik.github.io/charts
    helm repo update
    
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik-system \
        --create-namespace \
        --set "ports.web.redirectTo=websecure" \
        --set "ports.websecure.tls.enabled=true" \
        --set "providers.kubernetesCRD.enabled=true" \
        --set "providers.kubernetesIngress.enabled=true" \
        --set "globalArguments={--global.checknewversion=false,--global.sendanonymoususage=false}" \
        --wait
    
    success "Traefik installed successfully"
}

install_argocd() {
    log "Installing ArgoCD..."
    
    # Create namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Install ArgoCD
    kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
    
    # Wait for ArgoCD to be ready
    log "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
    
    # Patch ArgoCD server service to NodePort
    kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080},{"port":443,"nodePort":30443}]}}'
    
    # Get initial admin password
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    success "ArgoCD installed successfully"
    log "ArgoCD UI: https://localhost:30443"
    log "Username: admin"
    log "Password: $ARGOCD_PASSWORD"
}

install_sealed_secrets() {
    log "Installing Sealed Secrets controller..."
    
    kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/$SEALED_SECRETS_VERSION/controller.yaml"
    
    # Wait for controller to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets-controller -n kube-system
    
    success "Sealed Secrets controller installed successfully"
}

install_metrics_server() {
    log "Installing Metrics Server..."
    
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
    helm repo update
    
    helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --set args="{--cert-dir=/tmp,--secure-port=4443,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname,--kubelet-use-node-status-port,--metric-resolution=15s,--kubelet-insecure-tls}" \
        --wait
    
    success "Metrics Server installed successfully"
}

setup_gitops() {
    log "Setting up GitOps applications..."
    
    # Wait a bit for ArgoCD to be fully ready
    sleep 30
    
    # Apply app-of-apps
    kubectl apply -f ../app-of-apps.yaml
    
    success "GitOps applications configured"
    log "ArgoCD will sync applications automatically"
}

add_hosts_entries() {
    log "Adding hosts entries for local development..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        echo "127.0.0.1 todo-dev.local" | sudo tee -a /etc/hosts
        echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        # Windows (Git Bash/WSL)
        if command -v wsl.exe &> /dev/null; then
            # WSL environment
            echo "127.0.0.1 todo-dev.local" | sudo tee -a /etc/hosts
            echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts
        else
            warning "Please add the following to your Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts):"
            echo "127.0.0.1 todo-dev.local"
            echo "127.0.0.1 argocd.local"
        fi
    else
        warning "Unknown OS. Please manually add hosts entries:"
        echo "127.0.0.1 todo-dev.local"
        echo "127.0.0.1 argocd.local"
    fi
}

print_summary() {
    echo
    success "🚀 k3d cluster setup completed!"
    echo
    echo "📋 Cluster Information:"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Kubernetes API: https://localhost:6550"
    echo "  Container Registry: k3d-registry.localhost:$REGISTRY_PORT"
    echo
    echo "🔧 Services:"
    echo "  ArgoCD UI: https://localhost:30443"
    echo "  ArgoCD Username: admin"
    echo "  ArgoCD Password: $ARGOCD_PASSWORD"
    echo
    echo "🌐 Application URLs (after deployment):"
    echo "  TODO App (Dev): http://todo-dev.local:8080"
    echo
    echo "📚 Useful Commands:"
    echo "  kubectl get pods -A                    # View all pods"
    echo "  kubectl get applications -n argocd     # View ArgoCD applications"
    echo "  k3d cluster delete $CLUSTER_NAME       # Delete cluster"
    echo "  kubectl port-forward -n argocd svc/argocd-server 8080:80  # Alternative ArgoCD access"
    echo
    echo "🔑 Next Steps:"
    echo "  1. Build and push your todo-app image to the local registry"
    echo "  2. Access ArgoCD UI and sync applications"
    echo "  3. Monitor deployments: kubectl get pods -n todo-dev"
    echo
}

main() {
    log "Starting k3d cluster bootstrap for TODO GitOps demo"
    
    check_dependencies
    create_cluster
    install_traefik
    install_metrics_server
    install_sealed_secrets
    install_argocd
    setup_gitops
    add_hosts_entries
    print_summary
}

# Run main function
main "$@"