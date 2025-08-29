# Troubleshooting Guide

## Quick Diagnostics

### 🔍 Health Check Commands

```bash
# Overall cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

# ArgoCD health
kubectl get applications -n argocd
argocd app list

# Application health
kubectl get pods,svc,ingress -n todo-dev
kubectl get pods,svc,ingress -n todo-staging

# Resource usage
kubectl top nodes
kubectl top pods -A
```

## 🚨 Common Issues & Solutions

### 1. ArgoCD Application Stuck in "Progressing"

**Symptoms:**
- Application shows "Progressing" status for extended time
- Pods not starting or in pending state

**Diagnosis:**
```bash
argocd app get todo-dev
kubectl describe pod <pod-name> -n todo-dev
kubectl get events -n todo-dev --sort-by='.lastTimestamp'
```

**Solutions:**

#### A. Resource Constraints
```bash
# Check node resources
kubectl describe nodes

# Check resource quotas
kubectl get resourcequota -A

# Solution: Scale down or increase resources
kubectl scale deployment todo -n todo-dev --replicas=1
```

#### B. Image Pull Issues
```bash
# Check image exists
docker pull k3d-registry.localhost:5001/todo-app:latest

# Solution: Rebuild and push image
cd ../todo-app
docker build -t k3d-registry.localhost:5001/todo-app:latest .
docker push k3d-registry.localhost:5001/todo-app:latest
```

#### C. Configuration Issues
```bash
# Check configmaps and secrets
kubectl get configmap,secret -n todo-dev

# Solution: Fix sealed secrets
kubeseal --fetch-cert > public.pem
echo -n 'new-password' | kubeseal --raw --from-file=/dev/stdin --name redis-secret --namespace todo-dev --cert public.pem
```

### 2. Pod CrashLoopBackOff

**Symptoms:**
- Pods continuously restarting
- Application not accessible

**Diagnosis:**
```bash
kubectl logs <pod-name> -n todo-dev --previous
kubectl describe pod <pod-name> -n todo-dev
```

**Common Causes & Solutions:**

#### A. Redis Connection Issues
```bash
# Check Redis status
kubectl get pods -n todo-dev | grep redis
kubectl logs <redis-pod> -n todo-dev

# Test Redis connectivity
kubectl exec -it <todo-pod> -n todo-dev -- nc -zv <redis-service> 6379

# Solution: Check Redis password in sealed secret
kubectl get secret redis-secret -n todo-dev -o yaml
```

#### B. Environment Variable Issues
```bash
# Check environment variables
kubectl exec -it <pod-name> -n todo-dev -- env | grep -E "(REDIS|NODE)"

# Solution: Update deployment or configmap
kubectl edit deployment todo -n todo-dev
```

#### C. Health Check Failures
```bash
# Check health endpoint
kubectl exec -it <pod-name> -n todo-dev -- curl localhost:3000/healthz

# Solution: Adjust health check timing
kubectl patch deployment todo -n todo-dev -p '{"spec":{"template":{"spec":{"containers":[{"name":"todo","livenessProbe":{"initialDelaySeconds":60}}]}}}}'
```

### 3. Ingress/Networking Issues

**Symptoms:**
- Application not accessible via browser
- Timeout errors
- DNS resolution failures

**Diagnosis:**
```bash
# Check ingress
kubectl get ingress -n todo-dev
kubectl describe ingress todo -n todo-dev

# Check service endpoints
kubectl get endpoints -n todo-dev

# Check Traefik
kubectl logs -f deployment/traefik -n traefik-system
```

**Solutions:**

#### A. Host Resolution
```bash
# Add to /etc/hosts (Linux) or C:\Windows\System32\drivers\etc\hosts (Windows)
echo "127.0.0.1 todo-dev.local" >> /etc/hosts

# Or use port-forward as alternative
kubectl port-forward svc/todo -n todo-dev 8080:80
```

#### B. Traefik Configuration
```bash
# Check Traefik configuration
kubectl get ingressroute -A
kubectl get middleware -A

# Restart Traefik if needed
kubectl rollout restart deployment traefik -n traefik-system
```

#### C. Service Issues
```bash
# Check service selector matches pod labels
kubectl get pods -n todo-dev --show-labels
kubectl get svc todo -n todo-dev -o yaml

# Test internal connectivity
kubectl run debug --image=busybox -it --rm --restart=Never -- wget -O- http://todo.todo-dev.svc.cluster.local
```

### 4. ArgoCD Sync Failures

**Symptoms:**
- "OutOfSync" status
- "SyncFailed" errors
- Deployment not updating

**Diagnosis:**
```bash
argocd app get todo-dev --show-operation
argocd app diff todo-dev
kubectl get events -n argocd
```

**Solutions:**

#### A. Manifest Validation Errors
```bash
# Validate manifests locally
helm template todo ../todo-app/charts/todo -f ../todo-app/charts/todo/values-dev.yaml | kubectl apply --dry-run=client -f -

# Solution: Fix Helm chart or values
cd ../todo-app/charts/todo
helm lint .
```

#### B. Permission Issues
```bash
# Check ArgoCD service account permissions
kubectl get clusterrolebinding | grep argocd
kubectl describe clusterrolebinding argocd-server

# Solution: Ensure proper RBAC
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

#### C. Repository Access Issues
```bash
# Check repository configuration
argocd repo list
argocd repo get https://github.com/your-org/todo-app

# Solution: Update repository credentials
argocd repo add https://github.com/your-org/todo-app --username <user> --password <token>
```

### 5. Sealed Secrets Issues

**Symptoms:**
- Secrets not being created
- "SealedSecretController" errors
- Pod unable to mount secrets

**Diagnosis:**
```bash
# Check sealed secrets controller
kubectl get pods -n kube-system | grep sealed-secrets
kubectl logs -f deployment/sealed-secrets-controller -n kube-system

# Check sealed secret status
kubectl get sealedsecrets -A
kubectl describe sealedsecret redis-secret -n todo-dev
```

**Solutions:**

#### A. Controller Not Running
```bash
# Reinstall sealed secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Wait for controller to be ready
kubectl wait --for=condition=available --timeout=300s deployment/sealed-secrets-controller -n kube-system
```

#### B. Encryption Issues
```bash
# Get public key from cluster
kubeseal --fetch-cert > public.pem

# Re-encrypt secret with correct key
echo -n 'your-secret' | kubeseal --raw --from-file=/dev/stdin --name redis-secret --namespace todo-dev --cert public.pem
```

#### C. Namespace Issues
```bash
# Ensure namespace exists before applying sealed secret
kubectl create namespace todo-dev --dry-run=client -o yaml | kubectl apply -f -

# Apply sealed secret after namespace creation
kubectl apply -f environments/dev/redis-sealedsecret.yaml
```

### 6. HPA (Horizontal Pod Autoscaler) Issues

**Symptoms:**
- HPA not scaling pods
- "unable to get metrics" errors
- CPU/Memory metrics unavailable

**Diagnosis:**
```bash
# Check HPA status
kubectl get hpa -n todo-dev
kubectl describe hpa todo -n todo-dev

# Check metrics server
kubectl top pods -n todo-dev
kubectl get pods -n kube-system | grep metrics-server
```

**Solutions:**

#### A. Metrics Server Issues
```bash
# Check metrics server logs
kubectl logs -f deployment/metrics-server -n kube-system

# Reinstall metrics server with correct configuration
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--cert-dir=/tmp,--secure-port=4443,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname,--kubelet-use-node-status-port,--metric-resolution=15s,--kubelet-insecure-tls}"
```

#### B. Resource Requests Not Set
```bash
# Check if resource requests are defined
kubectl get deployment todo -n todo-dev -o yaml | grep -A 10 resources

# Solution: Ensure resource requests are set in Helm values
resources:
  requests:
    cpu: 100m
    memory: 128Mi
```

#### C. Load Generation for Testing
```bash
# Generate load to test HPA
kubectl run -i --tty load-generator --rm --image=busybox --restart=Never -- /bin/sh
# In the pod:
while true; do wget -q -O- http://todo.todo-dev.svc.cluster.local/api/todos; done

# Monitor scaling
kubectl get hpa -n todo-dev -w
```

## 🔄 Recovery Procedures

### Complete Cluster Reset

```bash
# Delete cluster
k3d cluster delete todo-local

# Recreate cluster
cd bootstrap
./setup.sh
```

### Application Recovery

```bash
# Delete and recreate application
argocd app delete todo-dev --cascade
kubectl apply -f applications/todo-dev.yaml

# Force refresh and sync
argocd app get todo-dev --refresh
argocd app sync todo-dev --prune
```

### Database Recovery (Redis)

```bash
# Backup current data (if accessible)
kubectl exec <redis-pod> -n todo-dev -- redis-cli BGSAVE

# Delete and recreate Redis
kubectl delete statefulset <redis-statefulset> -n todo-dev
kubectl delete pvc -l app.kubernetes.io/name=redis -n todo-dev

# Trigger ArgoCD sync to recreate
argocd app sync todo-dev
```

## 📊 Performance Debugging

### Resource Usage Analysis

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage by namespace
kubectl top pods -A --sort-by=cpu
kubectl top pods -A --sort-by=memory

# Detailed pod metrics
kubectl describe pod <pod-name> -n todo-dev | grep -A 5 -B 5 "Requests\|Limits"
```

### Network Performance

```bash
# Test internal network latency
kubectl run netshoot --rm -it --image nicolaka/netshoot -- /bin/bash
# Inside the pod:
curl -w "@curl-format.txt" -o /dev/null -s http://todo.todo-dev.svc.cluster.local/healthz
```

### Application Performance

```bash
# Check application metrics
kubectl port-forward svc/todo -n todo-dev 3000:80
curl http://localhost:3000/metrics

# Monitor response times
while true; do
  curl -w "Time: %{time_total}s\n" -o /dev/null -s http://todo-dev.local:8080/healthz
  sleep 1
done
```

## 🆘 Emergency Contacts & Escalation

### Immediate Response (P0/P1 Issues)

1. **Check monitoring dashboards**
2. **Review recent deployments**: `argocd app history todo-dev`
3. **Quick rollback if needed**: `argocd app rollback todo-dev <previous-revision>`
4. **Escalate to on-call engineer**

### Escalation Matrix

| Issue Severity | Response Time | Contact |
|----------------|---------------|---------|
| P0 - Service Down | 15 minutes | On-call engineer + Team lead |
| P1 - Major Degradation | 1 hour | Team lead |
| P2 - Minor Issues | 4 hours | Team member |
| P3 - Enhancement | Next business day | Backlog |

### Emergency Rollback

```bash
# Quick rollback to last known good state
argocd app rollback todo-dev

# Manual rollback
kubectl rollout undo deployment/todo -n todo-dev

# Complete environment reset
argocd app sync todo-dev --revision <last-good-commit>
```

## 📚 Additional Resources

- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug-application-cluster/)
- [ArgoCD Troubleshooting](https://argo-cd.readthedocs.io/en/stable/operator-manual/troubleshooting/)
- [Helm Debugging](https://helm.sh/docs/helm/helm_template/)
- [k3d Troubleshooting](https://k3d.io/v5.4.6/usage/troubleshooting/)

## 🔧 Useful Scripts

Save these as executable scripts for quick debugging:

### quick-debug.sh
```bash
#!/bin/bash
echo "=== Cluster Status ==="
kubectl get nodes
echo "=== Failed Pods ==="
kubectl get pods -A | grep -v Running | grep -v Completed
echo "=== ArgoCD Apps ==="
argocd app list
echo "=== Recent Events ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -10
```

### app-debug.sh
```bash
#!/bin/bash
NAMESPACE=${1:-todo-dev}
echo "=== Debugging namespace: $NAMESPACE ==="
kubectl get all -n $NAMESPACE
echo "=== Pod Logs ==="
kubectl logs -l app.kubernetes.io/name=todo -n $NAMESPACE --tail=20
echo "=== Recent Events ==="
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -5
```