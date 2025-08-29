# TODO GitOps Repository

This repository contains the GitOps configuration for the TODO application using ArgoCD with an app-of-apps pattern.

## 🏗️ Architecture Overview

```
todo-gitops/
├── app-of-apps.yaml              # Main ArgoCD application managing all apps
├── applications/                 # ArgoCD application definitions
│   ├── todo-dev.yaml            # Development environment
│   ├── todo-staging.yaml        # Staging environment
│   └── sealed-secrets.yaml     # Sealed Secrets controller
├── environments/                 # Environment-specific configurations
│   ├── dev/                     # Development environment
│   │   └── redis-sealedsecret.yaml
│   └── staging/                 # Staging environment
│       └── redis-sealedsecret.yaml
├── bootstrap/                   # Cluster setup scripts
│   ├── setup.sh                # Linux/WSL setup script
│   └── setup.bat               # Windows setup script
└── docs/                       # Documentation
```

## 🚀 Quick Start

### Prerequisites

#### Windows (WSL2 recommended)
```powershell
# Install WSL2 with Ubuntu
wsl --install -d Ubuntu

# Install Docker Desktop with WSL2 backend
# Download from: https://www.docker.com/products/docker-desktop

# In WSL2 terminal:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

#### Linux
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install ArgoCD CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd

# Install kubeseal (for Sealed Secrets)
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### 🔧 Cluster Setup

#### Option 1: Using Bootstrap Script (Recommended)

**Linux/WSL2:**
```bash
cd bootstrap
chmod +x setup.sh
./setup.sh
```

**Windows:**
```cmd
cd bootstrap
setup.bat
```

#### Option 2: Manual Setup

```bash
# Create k3d cluster
k3d cluster create todo-local \
  --api-port 6550 \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --registry-create "k3d-registry.localhost:5001" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

# Install Traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --wait

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Expose ArgoCD UI
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080},{"port":443,"nodePort":30443}]}}'

# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 📱 Access Services

After setup completion:

- **ArgoCD UI**: https://localhost:30443
  - Username: `admin`
  - Password: (from setup output)
- **TODO App (Dev)**: http://todo-dev.local:8080 (after deployment)
- **Kubernetes API**: https://localhost:6550

## 🔐 Secret Management

This repository uses [Sealed Secrets](https://sealed-secrets.netlify.app/) for secure secret management in GitOps.

### Creating Sealed Secrets

```bash
# Create a secret
echo -n 'my-secret-password' | kubeseal --raw --from-file=/dev/stdin --name redis-secret --namespace todo-dev

# Create sealed secret manifest
cat > redis-sealedsecret.yaml << EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: redis-secret
  namespace: todo-dev
spec:
  encryptedData:
    redis-password: <encrypted-value-from-above>
  template:
    metadata:
      name: redis-secret
      namespace: todo-dev
    type: Opaque
EOF
```

### Updating Secrets

1. Create new sealed secret with kubeseal
2. Update the respective environment file
3. Commit and push changes
4. ArgoCD will automatically sync the new secret

## 🚀 Deployment Workflow

### Development Environment
- **Auto-sync**: Enabled
- **Source**: `todo-app` repository, `main` branch
- **Image Tag**: `latest`
- **Namespace**: `todo-dev`

### Staging Environment
- **Auto-sync**: Disabled (manual approval required)
- **Source**: `todo-app` repository, `main` branch
- **Image Tag**: `stable`
- **Namespace**: `todo-staging`

### GitOps Flow

1. **Code Changes**: Developers push to `todo-app` repository
2. **CI/CD**: GitHub Actions builds and pushes container image
3. **Auto-Deployment**: ArgoCD detects changes and deploys to dev
4. **Manual Promotion**: DevOps team manually syncs staging environment
5. **Monitoring**: Health checks and metrics monitoring

## 📊 Monitoring & Observability

### Health Checks
```bash
# Check application health
kubectl get applications -n argocd

# Check pod status
kubectl get pods -n todo-dev
kubectl get pods -n todo-staging

# Check ArgoCD sync status
argocd app list
argocd app get todo-dev
```

### Metrics
- **Application Metrics**: Available at `/metrics` endpoint
- **Kubernetes Metrics**: Metrics Server installed
- **HPA Status**: `kubectl get hpa -n todo-dev`

### Logging
```bash
# Application logs
kubectl logs -f deployment/todo -n todo-dev

# ArgoCD logs
kubectl logs -f deployment/argocd-server -n argocd
```

## 🔄 Common Operations

### Sync Applications Manually
```bash
# Sync development environment
argocd app sync todo-dev

# Sync staging environment
argocd app sync todo-staging

# Sync all applications
argocd app sync -l environment=dev
```

### Update Application Images
```bash
# Update dev environment image tag
argocd app set todo-dev --parameter image.tag=v1.2.3

# Update staging environment image tag
argocd app set todo-staging --parameter image.tag=v1.2.3
```

### Scale Applications
```bash
# Scale dev environment
kubectl scale deployment todo -n todo-dev --replicas=3

# Check HPA status
kubectl get hpa -n todo-dev
```

## 🧪 Testing Autoscaling

### Load Testing with kubectl
```bash
# Create load generator pod
kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh

# Inside the pod, generate load
while true; do wget -q -O- http://todo.todo-dev.svc.cluster.local/api/todos; done
```

### Load Testing with k6
```bash
# Install k6
sudo apt-get update
sudo apt-get install k6

# Create load test script
cat > load-test.js << 'EOF'
import http from 'k6/http';
import { check } from 'k6';

export let options = {
  stages: [
    { duration: '2m', target: 20 },
    { duration: '5m', target: 20 },
    { duration: '2m', target: 0 },
  ],
};

export default function () {
  let response = http.get('http://todo-dev.local:8080/api/todos');
  check(response, { 'status was 200': (r) => r.status == 200 });
}
EOF

# Run load test
k6 run load-test.js
```

Monitor scaling:
```bash
# Watch HPA scaling
kubectl get hpa -n todo-dev -w

# Watch pod scaling
kubectl get pods -n todo-dev -w
```

## 🔧 Troubleshooting

### ArgoCD Issues

**Application Stuck in Progressing:**
```bash
# Check application status
argocd app get todo-dev

# Check events
kubectl get events -n todo-dev --sort-by='.lastTimestamp'

# Force refresh
argocd app get todo-dev --refresh
```

**Sync Failures:**
```bash
# Check sync status
argocd app get todo-dev --show-operation

# Manual sync with prune
argocd app sync todo-dev --prune

# Reset application
argocd app actions run todo-dev restart --kind Deployment
```

### Pod Issues

**Pods Not Starting:**
```bash
# Check pod status
kubectl describe pod <pod-name> -n todo-dev

# Check logs
kubectl logs <pod-name> -n todo-dev

# Check events
kubectl get events -n todo-dev --field-selector involvedObject.name=<pod-name>
```

**ImagePullBackOff:**
```bash
# Check image exists in registry
docker pull k3d-registry.localhost:5001/todo-app:latest

# Check secret for private registries
kubectl get secrets -n todo-dev
kubectl describe secret <image-pull-secret> -n todo-dev
```

### Networking Issues

**Service Not Accessible:**
```bash
# Check service
kubectl get svc -n todo-dev
kubectl describe svc todo -n todo-dev

# Check endpoints
kubectl get endpoints -n todo-dev

# Test internal connectivity
kubectl run debug --image=busybox -it --rm --restart=Never -- nslookup todo.todo-dev.svc.cluster.local
```

**Ingress Issues:**
```bash
# Check ingress
kubectl get ingress -n todo-dev
kubectl describe ingress todo -n todo-dev

# Check Traefik logs
kubectl logs -f deployment/traefik -n traefik-system
```

### Resource Issues

**Out of Resources:**
```bash
# Check node resources
kubectl top nodes
kubectl describe nodes

# Check pod resources
kubectl top pods -n todo-dev

# Check resource quotas
kubectl get resourcequota -n todo-dev
```

### Rollback Procedures

**Rollback Deployment:**
```bash
# Check rollout history
kubectl rollout history deployment/todo -n todo-dev

# Rollback to previous version
kubectl rollout undo deployment/todo -n todo-dev

# Rollback to specific revision
kubectl rollout undo deployment/todo --to-revision=2 -n todo-dev
```

**Rollback via ArgoCD:**
```bash
# View application history
argocd app history todo-dev

# Rollback to previous version
argocd app rollback todo-dev <revision-id>
```

## 📚 Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Sealed Secrets Documentation](https://sealed-secrets.netlify.app/)
- [k3d Documentation](https://k3d.io/)
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Test locally with the bootstrap script
5. Commit your changes: `git commit -am 'Add some feature'`
6. Push to the branch: `git push origin feature/my-feature`
7. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.