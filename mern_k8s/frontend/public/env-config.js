// Default runtime config used during local `npm start`.
// In the container this file is OVERWRITTEN at startup by docker-entrypoint.sh
// using the BACKEND_URL environment variable. Do not hard-code prod values here.
window._env_ = {
  BACKEND_URL: "http://localhost:5000"
};
