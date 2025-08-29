# TODO App

A cloud-native TODO service built with Node.js, Express, and Redis, designed for Kubernetes deployment with GitOps workflows.

## Features

- **RESTful API** with full CRUD operations for TODO items
- **Health checks** and **Prometheus metrics** endpoints
- **Redis integration** for data persistence
- **Security-first** approach with non-root containers
- **Kubernetes-ready** with Helm charts
- **GitOps-compatible** with ArgoCD

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/` | API information |
| GET | `/healthz` | Health check |
| GET | `/metrics` | Prometheus metrics |
| GET | `/api/todos` | List all todos |
| GET | `/api/todos/:id` | Get todo by ID |
| POST | `/api/todos` | Create new todo |
| PUT | `/api/todos/:id` | Update todo |
| DELETE | `/api/todos/:id` | Delete todo |

## Quick Start

### Local Development

```bash
# Install dependencies
npm install

# Start Redis (using Docker)
docker run -d --name redis -p 6379:6379 redis:alpine

# Start development server
npm run dev
```

### Docker

```bash
# Build image
docker build -t todo-app .

# Run with docker-compose
docker-compose up
```

### Kubernetes with Helm

```bash
# Add dependencies
helm dependency update charts/todo

# Install for development
helm install todo-dev charts/todo -f charts/todo/values-dev.yaml

# Install for staging
helm install todo-stg charts/todo -f charts/todo/values-stg.yaml
```

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `PORT` | `3000` | Server port |
| `NODE_ENV` | `production` | Node environment |
| `REDIS_URL` | `redis://localhost:6379` | Redis connection URL |
| `REDIS_PASSWORD` | - | Redis password |
| `LOG_LEVEL` | `info` | Logging level |

## API Examples

### Create a TODO

```bash
curl -X POST http://localhost:3000/api/todos \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Learn Kubernetes",
    "description": "Master container orchestration",
    "priority": "high",
    "dueDate": "2024-01-15T10:00:00Z"
  }'
```

### List all TODOs

```bash
curl http://localhost:3000/api/todos
```

### Update a TODO

```bash
curl -X PUT http://localhost:3000/api/todos/{id} \
  -H "Content-Type: application/json" \
  -d '{
    "completed": true
  }'
```

## Development

### Project Structure

```
├── src/
│   └── server.js          # Main application
├── charts/
│   └── todo/              # Helm chart
│       ├── templates/     # K8s manifests
│       ├── values.yaml    # Default values
│       ├── values-dev.yaml # Dev environment
│       └── values-stg.yaml # Staging environment
├── .github/
│   └── workflows/         # CI/CD pipelines
├── Dockerfile             # Container definition
└── package.json           # Dependencies
```

### Scripts

```bash
npm run start      # Start production server
npm run dev        # Start development server with hot reload
npm run test       # Run tests
npm run lint       # Run ESLint
npm run lint:fix   # Fix linting issues
```

## Deployment

### Environment Values

- **Development**: `values-dev.yaml` - Single replica, debug logging, no TLS
- **Staging**: `values-stg.yaml` - HA setup, HPA enabled, TLS configured

### CI/CD Pipeline

The GitHub Actions workflow includes:
- **Linting and testing** of Node.js code
- **Helm chart validation** with kubeval
- **Security scanning** with Trivy
- **Container image building** and pushing
- **SBOM generation** for security compliance

### GitOps Integration

This application is designed to work with ArgoCD:
- Helm charts are GitOps-ready
- Environment-specific value files
- Automatic synchronization support
- Health status reporting

## Monitoring

### Health Checks

- **Liveness**: `/healthz` - Application and Redis connectivity
- **Readiness**: `/healthz` - Same as liveness for this service

### Metrics

Prometheus metrics available at `/metrics`:
- `http_requests_total` - Total HTTP requests
- `http_request_duration_seconds` - Request duration histogram
- `todo_items_total` - Current number of TODO items

### Alerts

Recommended alerting rules:
- High error rate (>5%)
- High response time (>1s)
- Pod restart loops
- Redis connection failures

## Security

- **Non-root container** execution
- **Read-only root filesystem**
- **Security context** with dropped capabilities
- **Dependency scanning** with Renovate
- **Vulnerability scanning** with Trivy
- **SBOM generation** for supply chain security

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if needed
5. Run linting and tests
6. Submit a pull request

## License

MIT License - see LICENSE file for details.