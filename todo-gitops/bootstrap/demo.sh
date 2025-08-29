#!/bin/bash

# Demo script for testing autoscaling and showcasing GitOps functionality
# This script demonstrates the TODO app features and autoscaling capabilities

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="todo-dev"
APP_URL="http://todo-dev.local:8080"
LOAD_DURATION=300  # 5 minutes
TARGET_RPS=50

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] ✓ $1${NC}"
}

warning() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠ $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ✗ $1${NC}"
}

header() {
    echo -e "${PURPLE}════════════════════════════════════════${NC}"
    echo -e "${PURPLE} $1${NC}"
    echo -e "${PURPLE}════════════════════════════════════════${NC}"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed"
        exit 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        error "Namespace $NAMESPACE does not exist"
        exit 1
    fi
    
    # Check if TODO app is running
    if ! kubectl get deployment todo -n $NAMESPACE &> /dev/null; then
        error "TODO app deployment not found in namespace $NAMESPACE"
        exit 1
    fi
    
    success "All prerequisites met"
}

show_initial_state() {
    header "Initial Cluster State"
    
    log "Current pod count:"
    kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=todo
    
    log "HPA status:"
    kubectl get hpa -n $NAMESPACE
    
    log "Node resource usage:"
    kubectl top nodes
    
    log "Pod resource usage:"
    kubectl top pods -n $NAMESPACE
}

test_api_functionality() {
    header "Testing TODO API Functionality"
    
    log "Testing health endpoint..."
    if curl -f -s "$APP_URL/healthz" > /dev/null; then
        success "Health check passed"
    else
        error "Health check failed"
        return 1
    fi
    
    log "Testing metrics endpoint..."
    if curl -f -s "$APP_URL/metrics" > /dev/null; then
        success "Metrics endpoint accessible"
    else
        warning "Metrics endpoint not accessible"
    fi
    
    log "Creating sample TODO items..."
    
    # Create a few TODO items
    TODO_IDS=()
    for i in {1..5}; do
        RESPONSE=$(curl -s -X POST "$APP_URL/api/todos" \
            -H "Content-Type: application/json" \
            -d "{
                \"title\": \"Demo Task $i\",
                \"description\": \"This is a demo task created during the autoscaling test\",
                \"priority\": \"medium\",
                \"dueDate\": \"$(date -d '+1 day' -Iseconds)\"
            }")
        
        if [[ $? -eq 0 ]]; then
            TODO_ID=$(echo $RESPONSE | jq -r '.id')
            TODO_IDS+=($TODO_ID)
            success "Created TODO item $i with ID: $TODO_ID"
        else
            warning "Failed to create TODO item $i"
        fi
    done
    
    log "Listing all TODO items:"
    curl -s "$APP_URL/api/todos" | jq '.[0:3]' || echo "No items found or jq not available"
    
    # Mark some items as completed
    if [[ ${#TODO_IDS[@]} -gt 0 ]]; then
        log "Marking first TODO item as completed..."
        curl -s -X PUT "$APP_URL/api/todos/${TODO_IDS[0]}" \
            -H "Content-Type: application/json" \
            -d '{"completed": true}' > /dev/null
        success "TODO item marked as completed"
    fi
}

generate_load() {
    header "Generating Load for Autoscaling Demo"
    
    log "Starting load generation for $LOAD_DURATION seconds at $TARGET_RPS RPS..."
    log "Monitor scaling with: kubectl get hpa -n $NAMESPACE -w"
    
    # Create load test script
    cat > /tmp/load-test.sh << 'EOF'
#!/bin/bash
URL=$1
RPS=$2
DURATION=$3

echo "Starting load test: $RPS RPS for $DURATION seconds"
echo "Target URL: $URL"

END_TIME=$((SECONDS + DURATION))

while [ $SECONDS -lt $END_TIME ]; do
    for ((i=1; i<=RPS; i++)); do
        {
            # Mix of different endpoints to simulate real usage
            case $((i % 4)) in
                0) curl -s "$URL/api/todos" > /dev/null ;;
                1) curl -s "$URL/healthz" > /dev/null ;;
                2) curl -s "$URL/metrics" > /dev/null ;;
                3) curl -s -X POST "$URL/api/todos" \
                     -H "Content-Type: application/json" \
                     -d '{"title":"Load Test","description":"Generated during load test"}' > /dev/null ;;
            esac
        } &
    done
    sleep 1
    
    # Cleanup background jobs to prevent accumulation
    if (( $(jobs -r | wc -l) > 100 )); then
        wait
    fi
done

wait
echo "Load test completed"
EOF

    chmod +x /tmp/load-test.sh
    
    # Start load test in background
    /tmp/load-test.sh "$APP_URL" "$TARGET_RPS" "$LOAD_DURATION" &
    LOAD_PID=$!
    
    log "Load test started with PID: $LOAD_PID"
    log "You can monitor the following in separate terminals:"
    echo -e "  ${CYAN}kubectl get hpa -n $NAMESPACE -w${NC}    # Watch HPA scaling"
    echo -e "  ${CYAN}kubectl get pods -n $NAMESPACE -w${NC}    # Watch pod creation"
    echo -e "  ${CYAN}kubectl top pods -n $NAMESPACE${NC}       # Pod resource usage"
    
    # Monitor scaling progress
    monitor_scaling $LOAD_PID
}

monitor_scaling() {
    local load_pid=$1
    local check_interval=10
    local max_pods_seen=1
    
    log "Monitoring autoscaling progress (checking every ${check_interval}s)..."
    
    while kill -0 $load_pid 2>/dev/null; do
        # Get current metrics
        CURRENT_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=todo --no-headers | wc -l)
        HPA_STATUS=$(kubectl get hpa -n $NAMESPACE -o jsonpath='{.items[0].status.currentReplicas}/{.items[0].status.desiredReplicas}' 2>/dev/null || echo "N/A")
        CPU_USAGE=$(kubectl top pods -n $NAMESPACE -l app.kubernetes.io/name=todo --no-headers 2>/dev/null | awk '{sum+=$2} END {print sum "m"}' || echo "N/A")
        
        # Track maximum pods seen
        if [[ $CURRENT_PODS -gt $max_pods_seen ]]; then
            max_pods_seen=$CURRENT_PODS
            success "Scaled up to $CURRENT_PODS pods! 🚀"
        fi
        
        log "Current status: $CURRENT_PODS pods (HPA: $HPA_STATUS), CPU usage: $CPU_USAGE"
        
        sleep $check_interval
    done
    
    success "Load test completed. Maximum pods reached: $max_pods_seen"
}

show_scaling_results() {
    header "Autoscaling Demo Results"
    
    log "Final pod count:"
    kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=todo
    
    log "HPA final status:"
    kubectl get hpa -n $NAMESPACE
    
    log "Pod resource usage:"
    kubectl top pods -n $NAMESPACE
    
    log "Recent scaling events:"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep -i "scaled\|horizontal" | tail -10
    
    log "Waiting for scale-down (this may take 5-10 minutes)..."
    log "You can monitor with: kubectl get pods -n $NAMESPACE -w"
}

show_argocd_status() {
    header "ArgoCD GitOps Status"
    
    if command -v argocd &> /dev/null; then
        log "ArgoCD applications status:"
        argocd app list 2>/dev/null || kubectl get applications -n argocd
        
        log "TODO app sync status:"
        argocd app get todo-dev 2>/dev/null || kubectl get application todo-dev -n argocd -o yaml
    else
        log "ArgoCD CLI not available, checking via kubectl:"
        kubectl get applications -n argocd
    fi
}

cleanup_demo_data() {
    header "Cleaning Up Demo Data"
    
    log "Removing demo TODO items..."
    
    # Get all TODO items and delete demo ones
    TODOS=$(curl -s "$APP_URL/api/todos" | jq -r '.[] | select(.title | contains("Demo Task") or contains("Load Test")) | .id' 2>/dev/null || echo "")
    
    if [[ -n "$TODOS" ]]; then
        while read -r todo_id; do
            if [[ -n "$todo_id" && "$todo_id" != "null" ]]; then
                curl -s -X DELETE "$APP_URL/api/todos/$todo_id" > /dev/null
                log "Deleted TODO item: $todo_id"
            fi
        done <<< "$TODOS"
        success "Demo data cleanup completed"
    else
        log "No demo data found to clean up"
    fi
}

show_useful_commands() {
    header "Useful Commands for Further Exploration"
    
    echo -e "${CYAN}Monitoring Commands:${NC}"
    echo "  kubectl get pods -n $NAMESPACE -w                    # Watch pod changes"
    echo "  kubectl get hpa -n $NAMESPACE -w                     # Watch HPA scaling"
    echo "  kubectl top pods -n $NAMESPACE                       # Resource usage"
    echo "  kubectl logs -f deployment/todo -n $NAMESPACE        # Application logs"
    echo
    echo -e "${CYAN}ArgoCD Commands:${NC}"
    echo "  argocd app list                                       # List applications"
    echo "  argocd app get todo-dev                               # App details"
    echo "  argocd app sync todo-dev                              # Force sync"
    echo
    echo -e "${CYAN}API Testing:${NC}"
    echo "  curl $APP_URL/healthz                                # Health check"
    echo "  curl $APP_URL/metrics                                # Prometheus metrics"
    echo "  curl $APP_URL/api/todos                              # List TODOs"
    echo
    echo -e "${CYAN}Load Testing:${NC}"
    echo "  kubectl run loadtest --rm -it --image=busybox -- sh  # Interactive load test pod"
    echo "  # Inside pod: while true; do wget -q -O- http://todo.todo-dev.svc.cluster.local; done"
    echo
    echo -e "${CYAN}Access URLs:${NC}"
    echo "  TODO App: $APP_URL"
    echo "  ArgoCD UI: https://localhost:30443"
    echo "  Grafana (if installed): http://localhost:3000"
}

main() {
    clear
    echo -e "${PURPLE}"
    cat << 'EOF'
████████╗ ██████╗ ██████╗  ██████╗      ██████╗ ██╗████████╗ ██████╗ ██████╗ ███████╗
╚══██╔══╝██╔═══██╗██╔══██╗██╔═══██╗    ██╔════╝ ██║╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
   ██║   ██║   ██║██║  ██║██║   ██║    ██║  ███╗██║   ██║   ██║   ██║██████╔╝███████╗
   ██║   ██║   ██║██║  ██║██║   ██║    ██║   ██║██║   ██║   ██║   ██║██╔═══╝ ╚════██║
   ██║   ╚██████╔╝██████╔╝╚██████╔╝    ╚██████╔╝██║   ██║   ╚██████╔╝██║     ███████║
   ╚═╝    ╚═════╝ ╚═════╝  ╚═════╝      ╚═════╝ ╚═╝   ╚═╝    ╚═════╝ ╚═╝     ╚══════╝
                                                                                        
   Kubernetes GitOps Demo with ArgoCD & Autoscaling
EOF
    echo -e "${NC}"
    
    log "Starting TODO GitOps autoscaling demonstration..."
    
    check_prerequisites
    show_initial_state
    test_api_functionality
    show_argocd_status
    
    echo
    read -p "Press Enter to start the autoscaling load test (this will run for ~5 minutes)..."
    
    generate_load
    show_scaling_results
    
    echo
    read -p "Press Enter to clean up demo data and show useful commands..."
    
    cleanup_demo_data
    show_useful_commands
    
    success "Demo completed! 🎉"
    log "The cluster will continue running. Use 'k3d cluster delete todo-local' to clean up."
}

# Handle interruption gracefully
trap 'error "Demo interrupted"; exit 1' INT TERM

# Run main function
main "$@"