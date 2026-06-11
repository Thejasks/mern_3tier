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

import React, { useState, useEffect } from 'react';
import axios from 'axios';
import './App.css';

// Resolve the backend URL at runtime (window._env_ is generated per-environment
// by the container entrypoint), falling back to a build-time var for local dev.
const BACKEND_URL =
  (typeof window !== 'undefined' && window._env_ && window._env_.BACKEND_URL) ||
  process.env.REACT_APP_BACKEND_URL ||
  'https://backend.acadcart.com';

console.log('BACKEND:', BACKEND_URL);
const API = axios.create({
  baseURL: BACKEND_URL,
  timeout: 5000,
  headers: { 'Content-Type': 'application/json' }
});

API.interceptors.request.use(config => {
  const token = localStorage.getItem('token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

API.interceptors.response.use(
  response => response,
  error => {
    if (error.response?.status === 401 && !error.config.url.includes('/api/login')) {
      localStorage.clear();
      window.location.reload();
    }
    return Promise.reject(error);
  }
);

const App = () => {
  const [state, setState] = useState({
    isAuthenticated: false,
    currentUser: null,
    users: [],
    form: { username: '', password: '' },
    error: '',
    success: '',
    loading: false,
    isLogin: true,
    checkingBackend: true,
    backendError: null
  });

  // Health check with retry logic (3 attempts)
  useEffect(() => {
    const checkBackend = async (retryCount = 0) => {
      try {
        const { data } = await API.get('/healthz');
        if (data.status === 'ok') {
          setState(prev => ({ ...prev, checkingBackend: false, backendError: null }));
        }
      } catch (error) {
        if (retryCount < 2) {
          setTimeout(() => checkBackend(retryCount + 1), 2000);
          return;
        }
        setState(prev => ({
          ...prev,
          checkingBackend: false,
          backendError: error.response?.data?.error || 'Backend service unavailable'
        }));
      }
    };
    checkBackend();
  }, []);

  useEffect(() => {
    const token = localStorage.getItem('token');
    const user = JSON.parse(localStorage.getItem('user'));
    if (token && user) {
      setState(prev => ({ ...prev, isAuthenticated: true, currentUser: user }));
    }
  }, []);

  useEffect(() => {
    const fetchUsers = async () => {
      try {
        const { data } = await API.get('/api/users');
        setState(prev => ({
          ...prev,
          users: Array.isArray(data) ? data : [],
          error: ''
        }));
      } catch (error) {
        setState(prev => ({
          ...prev,
          users: [],
          error: error.response?.data?.error || 'Failed to fetch users'
        }));
      }
    };
    
    if (state.isAuthenticated) fetchUsers();
  }, [state.isAuthenticated]);

  const validateForm = () => {
    const { username, password } = state.form;
    if (!username.trim() || !password.trim()) return 'All fields are required';
    if (username.length < 3) return 'Username must be at least 3 characters';
    if (password.length < 6) return 'Password must be at least 6 characters';
    return null;
  };

  const handleChange = (e) => {
    setState(prev => ({
      ...prev,
      form: { ...prev.form, [e.target.name]: e.target.value },
      error: ''
    }));
  };

  const handleAuth = async (e) => {
    e.preventDefault();
    const validationError = validateForm();
    if (validationError) {
      setState(prev => ({ ...prev, error: validationError }));
      return;
    }

    setState(prev => ({ ...prev, loading: true, error: '' }));
    
    try {
      const endpoint = state.isLogin ? '/api/login' : '/api/register';
      const { data } = await API.post(endpoint, state.form);

      if (state.isLogin) {
        localStorage.setItem('token', data.token);
        localStorage.setItem('user', JSON.stringify(data.user));
        setState(prev => ({
          ...prev,
          isAuthenticated: true,
          currentUser: data.user,
          loading: false,
          form: { username: '', password: '' }
        }));
      } else {
        setState(prev => ({
          ...prev,
          success: 'Registration successful! Please login.',
          isLogin: true,
          loading: false,
          form: { username: '', password: '' }
        }));
      }
    } catch (error) {
      const errorMessage = error.response?.data?.error || 
                        (state.isLogin ? 'Invalid username or password' : 'Registration failed');
      setState(prev => ({
        ...prev,
        error: errorMessage,
        loading: false,
        form: { ...prev.form, password: '' } // Clear password field
      }));
    }
  };

  const handleLogout = () => {
    localStorage.clear();
    setState(prev => ({
      ...prev,
      isAuthenticated: false,
      currentUser: null,
      users: [],
      form: { username: '', password: '' }
    }));
  };

  // Your existing UI below - completely unchanged
  if (state.checkingBackend) {
    return (
      <div className="container">
        <div className="health-check">
          <h2>Connecting to backend...</h2>
          <div className="spinner"></div>
          <p>Checking: {API.defaults.baseURL}</p>
        </div>
      </div>
    );
  }

  if (state.backendError) {
    return (
      <div className="container">
        <div className="error-panel">
          <h2>Connection Error</h2>
          <p>{state.backendError}</p>
          <p>Verify backend is running at:</p>
          <code>{API.defaults.baseURL}</code>
          <button 
            className="retry-btn"
            onClick={() => window.location.reload()}
          >
            Retry Connection
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="container">
      {!state.isAuthenticated ? (
        <div className="auth-box">
          <h2>{state.isLogin ? 'Login' : 'Register'}</h2>
          <form onSubmit={handleAuth}>
            <input
              name="username"
              placeholder="Username"
              onChange={handleChange}
              value={state.form.username}
              required
              minLength="3"
              maxLength="30"
            />
            <input
              name="password"
              type="password"
              placeholder="Password"
              onChange={handleChange}
              value={state.form.password}
              required
              minLength="6"
            />
            <button 
              type="submit" 
              disabled={state.loading}
              className={state.loading ? 'loading' : ''}
            >
              {state.loading ? (
                <div className="spinner"></div>
              ) : state.isLogin ? 'Login' : 'Register'}
            </button>
          </form>
          {state.error && <div className="alert error">{state.error}</div>}
          {state.success && <div className="alert success">{state.success}</div>}
          <p className="toggle" onClick={() => setState(prev => ({
            ...prev,
            isLogin: !prev.isLogin,
            error: '',
            form: { username: prev.form.username, password: '' }
          }))}>
            {state.isLogin 
              ? 'Need an account? Register here'
              : 'Already have an account? Login here'}
          </p>
        </div>
      ) : (
        <div className="dashboard">
          <div className="header">
            <h2>Welcome, {state.currentUser?.username}</h2>
            <button onClick={handleLogout} className="logout-btn">
              Logout
            </button>
          </div>
          <h3>Registered Users ({state.users.length})</h3>
          <ul className="user-list">
            {Array.isArray(state.users) && state.users.length > 0 ? (
              state.users.map(user => (
                <li key={user._id}>
                  <span>{user.username}</span>
                  <small>
                    Joined: {new Date(user.createdAt).toLocaleDateString()}
                  </small>
                </li>
              ))
            ) : (
              <li className="empty">
                {state.users.length === 0 
                  ? 'No users found' 
                  : 'Failed to load users'}
              </li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
};

export default App;