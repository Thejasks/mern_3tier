// Copyright 2024 itdefined.org

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

//     http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


const express = require('express');
const mongoose = require('mongoose');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const cors = require('cors');

const app = express();

// ======================
// Configuration
// ======================
const config = {
  // Server
  port: process.env.PORT || 3000,
  
  // MongoDB
  mongo: {
    host: process.env.MONGO_HOST || 'mongo-service',
    port: process.env.MONGO_PORT || 27017,
    dbName: process.env.MONGO_DB_NAME || 'userdb',
    authSource: process.env.MONGO_AUTH_SOURCE || 'admin',
    user: process.env.MONGO_USER,
    password: process.env.MONGO_PASSWORD
  },
  
  // JWT
  jwt: {
    secret: process.env.JWT_SECRET,
    expiresIn: process.env.JWT_EXPIRES_IN || '1h'
  },
  
  // CORS
  cors: {
    origins: process.env.CORS_ORIGIN 
      ? process.env.CORS_ORIGIN.split(',') 
      : ['http://localhost:3000']
  }
};

// ======================
// Validation
// ======================
const requiredEnvVars = [
  'MONGO_USER', 
  'MONGO_PASSWORD',
  'JWT_SECRET'
];

requiredEnvVars.forEach(varName => {
  if (!process.env[varName]) {
    console.error(`❌ FATAL ERROR: Missing required environment variable: ${varName}`);
    process.exit(1);
  }
});

/// ======================
// Database Setup (Corrected)
// ======================
const mongoURI = `mongodb://${
  encodeURIComponent(config.mongo.user)
}:${
  encodeURIComponent(config.mongo.password)
}@${
  config.mongo.host  // Remove any protocol prefix here
}:${
  config.mongo.port
}/${
  config.mongo.dbName
}?authSource=${
  config.mongo.authSource
}&retryWrites=true&w=majority`;

// Add validation for host format
if (config.mongo.host.includes('://')) {
  console.error('❌ Invalid MongoDB host format. Use just "mongo-service" without protocol');
  process.exit(1);
}

// Retry instead of crashing if Mongo isn't ready yet (pod startup ordering).
function connectWithRetry() {
  mongoose.connect(mongoURI, {
    useNewUrlParser: true,
    useUnifiedTopology: true,
    serverSelectionTimeoutMS: 5000,
    socketTimeoutMS: 45000,
    connectTimeoutMS: 10000
  }).catch(err => {
    console.error('Mongo connect failed, retrying in 5s:', err.message);
    setTimeout(connectWithRetry, 5000);
  });
}
connectWithRetry();

mongoose.connection.on('connected', () => {
  console.log('MongoDB connected to:', mongoose.connection.host);
});

mongoose.connection.on('error', (err) => {
  console.error('MongoDB connection error:', err);
});

// ======================
// Middleware
// ======================
app.use(express.json());
app.use(cors({
  origin: config.cors.origins,
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
  allowedHeaders: ['Content-Type', 'Authorization']
}));

// ======================
// User Model
// ======================
const UserSchema = new mongoose.Schema({
  username: { 
    type: String,
    required: true,
    unique: true,
    minlength: 3,
    maxlength: 30,
    match: /^[a-zA-Z0-9_]+$/
  },
  password: {
    type: String,
    required: true,
    minlength: 6
  },
  createdAt: { 
    type: Date, 
    default: Date.now 
  }
});

const User = mongoose.model('User', UserSchema);

// Add this before routes
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
  next();
});

// ======================
// Routes
// ======================

// Update registration route
app.post('/api/register', async (req, res) => {
  try {
    console.log('Registration attempt:', req.body);
    
    const { username, password } = req.body;
    
    if (!username || !password) {
      console.log('Missing credentials');
      return res.status(400).json({ error: 'Username and password required' });
    }

    const existingUser = await User.findOne({ username });
    if (existingUser) {
      console.log('Username conflict:', username);
      return res.status(409).json({ error: 'Username already exists' });
    }

    const user = new User({
      username,
      password: await bcrypt.hash(password, 10)
    });
    
    await user.save();
    console.log('User created:', user.username);
    
    res.status(201).json({ message: 'User created successfully' });
  } catch (error) {
    console.error('Registration error:', error);
    res.status(400).json({ error: 'Registration failed' });
  }
});

// Login
app.post('/api/login', async (req, res) => {
  try {
    const { username, password } = req.body;
    const user = await User.findOne({ username });

    if (!user || !(await bcrypt.compare(password, user.password))) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const token = jwt.sign(
      { id: user._id },
      config.jwt.secret,
      { expiresIn: config.jwt.expiresIn }
    );

    res.json({
      token,
      user: {
        id: user._id,
        username: user.username,
        createdAt: user.createdAt
      }
    });
  } catch (error) {
    console.error('Login error:', error);
    res.status(500).json({ error: 'Login failed' });
  }
});

// Protected Users List
app.get('/api/users', async (req, res) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) throw new Error('No token provided');
    
    jwt.verify(token, config.jwt.secret);
    const users = await User.find({}, 'username createdAt');
    res.json(users);
  } catch (error) {
    res.status(401).json({ error: 'Unauthorized' });
  }
});

// Health Check
app.get('/healthz', async (req, res) => {
  try {
    await mongoose.connection.db.admin().ping();
    res.json({
      status: 'ok',
      dbStatus: 'connected',
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(503).json({
      status: 'error',
      error: 'Database connection failed'
    });
  }
});

// ======================
// Server Management
// ======================
process.on('SIGTERM', gracefulShutdown);

function gracefulShutdown() {
  console.log('🛑 Received termination signal - shutting down');
  
  server.close(async () => {
    console.log('🔒 HTTP server closed');
    await mongoose.connection.close();
    console.log('🔒 Database connection closed');
    process.exit(0);
  });
}

const server = app.listen(config.port, '0.0.0.0', () => {
  console.log(`
  🚀 Server ready on port ${config.port}
  Environment: ${process.env.NODE_ENV || 'development'}
  MongoDB: ${config.mongo.host}:${config.mongo.port}
  CORS Allowed: ${config.cors.origins.join(', ')}
  `);
});