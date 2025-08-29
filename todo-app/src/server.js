const express = require('express')
const cors = require('cors')
const helmet = require('helmet')
const redis = require('redis')
const promClient = require('prom-client')
const { v4: uuidv4 } = require('uuid')
const Joi = require('joi')

class TodoApp {
  constructor() {
    this.app = express()
    this.client = null
    this.port = process.env.PORT || 3000
    this.redisUrl = process.env.REDIS_URL || 'redis://localhost:6379'
    
    // Prometheus metrics
    this.register = new promClient.Registry()
    this.httpRequestDuration = new promClient.Histogram({
      name: 'http_request_duration_seconds',
      help: 'Duration of HTTP requests in seconds',
      labelNames: ['method', 'route', 'status_code'],
      buckets: [0.1, 0.5, 1, 2, 5]
    })
    this.httpRequestTotal = new promClient.Counter({
      name: 'http_requests_total',
      help: 'Total number of HTTP requests',
      labelNames: ['method', 'route', 'status_code']
    })
    this.todoTotal = new promClient.Gauge({
      name: 'todo_items_total',
      help: 'Total number of TODO items'
    })
    
    this.register.registerMetric(this.httpRequestDuration)
    this.register.registerMetric(this.httpRequestTotal)
    this.register.registerMetric(this.todoTotal)
    this.register.setDefaultLabels({ app: 'todo-service' })
    
    this.setupMiddleware()
    this.setupRoutes()
  }

  async connectRedis() {
    try {
      this.client = redis.createClient({
        url: this.redisUrl,
        password: process.env.REDIS_PASSWORD || undefined
      })
      
      this.client.on('error', (err) => {
        console.error('Redis Client Error:', err)
      })
      
      await this.client.connect()
      console.log('Connected to Redis successfully')
    } catch (error) {
      console.error('Failed to connect to Redis:', error)
      throw error
    }
  }

  setupMiddleware() {
    this.app.use(helmet())
    this.app.use(cors())
    this.app.use(express.json({ limit: '10mb' }))
    
    // Metrics middleware
    this.app.use((req, res, next) => {
      const start = Date.now()
      
      res.on('finish', () => {
        const duration = (Date.now() - start) / 1000
        const route = req.route ? req.route.path : req.path
        
        this.httpRequestDuration
          .labels(req.method, route, res.statusCode)
          .observe(duration)
        
        this.httpRequestTotal
          .labels(req.method, route, res.statusCode)
          .inc()
      })
      
      next()
    })
  }

  setupRoutes() {
    // Health check endpoint
    this.app.get('/healthz', async (req, res) => {
      try {
        // Check Redis connection
        await this.client.ping()
        res.status(200).json({
          status: 'healthy',
          timestamp: new Date().toISOString(),
          uptime: process.uptime(),
          version: process.env.npm_package_version || '1.0.0'
        })
      } catch (error) {
        res.status(503).json({
          status: 'unhealthy',
          error: error.message,
          timestamp: new Date().toISOString()
        })
      }
    })

    // Metrics endpoint
    this.app.get('/metrics', async (req, res) => {
      try {
        // Update todo count metric
        const count = await this.getTodoCount()
        this.todoTotal.set(count)
        
        res.set('Content-Type', this.register.contentType)
        res.end(await this.register.metrics())
      } catch (error) {
        res.status(500).json({ error: 'Failed to retrieve metrics' })
      }
    })

    // Get all todos
    this.app.get('/api/todos', async (req, res) => {
      try {
        const todos = await this.getAllTodos()
        res.json(todos)
      } catch (error) {
        res.status(500).json({ error: error.message })
      }
    })

    // Get todo by ID
    this.app.get('/api/todos/:id', async (req, res) => {
      try {
        const todo = await this.getTodoById(req.params.id)
        if (!todo) {
          return res.status(404).json({ error: 'Todo not found' })
        }
        res.json(todo)
      } catch (error) {
        res.status(500).json({ error: error.message })
      }
    })

    // Create new todo
    this.app.post('/api/todos', async (req, res) => {
      try {
        const { error, value } = this.validateTodo(req.body)
        if (error) {
          return res.status(400).json({ error: error.details[0].message })
        }

        const todo = await this.createTodo(value)
        res.status(201).json(todo)
      } catch (error) {
        res.status(500).json({ error: error.message })
      }
    })

    // Update todo
    this.app.put('/api/todos/:id', async (req, res) => {
      try {
        const { error, value } = this.validateTodo(req.body, true)
        if (error) {
          return res.status(400).json({ error: error.details[0].message })
        }

        const todo = await this.updateTodo(req.params.id, value)
        if (!todo) {
          return res.status(404).json({ error: 'Todo not found' })
        }
        res.json(todo)
      } catch (error) {
        res.status(500).json({ error: error.message })
      }
    })

    // Delete todo
    this.app.delete('/api/todos/:id', async (req, res) => {
      try {
        const deleted = await this.deleteTodo(req.params.id)
        if (!deleted) {
          return res.status(404).json({ error: 'Todo not found' })
        }
        res.status(204).send()
      } catch (error) {
        res.status(500).json({ error: error.message })
      }
    })

    // Root endpoint
    this.app.get('/', (req, res) => {
      res.json({
        name: 'TODO API',
        version: process.env.npm_package_version || '1.0.0',
        endpoints: {
          health: '/healthz',
          metrics: '/metrics',
          todos: '/api/todos'
        }
      })
    })
  }

  validateTodo(data, isUpdate = false) {
    const schema = Joi.object({
      title: Joi.string().min(1).max(255).required(),
      description: Joi.string().max(1000).optional(),
      completed: Joi.boolean().optional(),
      priority: Joi.string().valid('low', 'medium', 'high').default('medium'),
      dueDate: Joi.date().iso().optional()
    })

    return schema.validate(data)
  }

  async getAllTodos() {
    const keys = await this.client.keys('todo:*')
    if (keys.length === 0) return []

    const todos = await this.client.mGet(keys)
    return todos.map(todo => JSON.parse(todo)).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
  }

  async getTodoById(id) {
    const todo = await this.client.get(`todo:${id}`)
    return todo ? JSON.parse(todo) : null
  }

  async createTodo(todoData) {
    const id = uuidv4()
    const todo = {
      id,
      ...todoData,
      completed: todoData.completed || false,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    }

    await this.client.set(`todo:${id}`, JSON.stringify(todo))
    return todo
  }

  async updateTodo(id, updateData) {
    const existing = await this.getTodoById(id)
    if (!existing) return null

    const updated = {
      ...existing,
      ...updateData,
      id: existing.id, // Ensure ID doesn't change
      createdAt: existing.createdAt, // Preserve creation date
      updatedAt: new Date().toISOString()
    }

    await this.client.set(`todo:${id}`, JSON.stringify(updated))
    return updated
  }

  async deleteTodo(id) {
    const exists = await this.client.exists(`todo:${id}`)
    if (!exists) return false

    await this.client.del(`todo:${id}`)
    return true
  }

  async getTodoCount() {
    const keys = await this.client.keys('todo:*')
    return keys.length
  }

  async start() {
    try {
      await this.connectRedis()
      
      this.server = this.app.listen(this.port, () => {
        console.log(`TODO API server running on port ${this.port}`)
        console.log(`Health check: http://localhost:${this.port}/healthz`)
        console.log(`Metrics: http://localhost:${this.port}/metrics`)
        console.log(`API docs: http://localhost:${this.port}/`)
      })
    } catch (error) {
      console.error('Failed to start server:', error)
      process.exit(1)
    }
  }

  async stop() {
    if (this.client) {
      await this.client.quit()
    }
    if (this.server) {
      this.server.close()
    }
  }
}

// Start the application
if (require.main === module) {
  const app = new TodoApp()
  
  // Graceful shutdown
  process.on('SIGTERM', async () => {
    console.log('SIGTERM received, shutting down gracefully')
    await app.stop()
    process.exit(0)
  })

  process.on('SIGINT', async () => {
    console.log('SIGINT received, shutting down gracefully')
    await app.stop()
    process.exit(0)
  })

  app.start()
}

module.exports = TodoApp