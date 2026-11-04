# Base image: Node 22 on Alpine, a small Linux image with Node preinstalled.
FROM node:22-alpine

# Set the working folder inside the image. Docker creates it if it is missing.
WORKDIR /app

# Copy only server.js from the build context (mock-fhir/). The mock has no
# dependencies, so nothing else is needed at runtime.
COPY server.js ./server.js

# Switch to the built-in unprivileged "node" user. The server runs without root rights.
USER node

# Documentation only: declares that the server listens on port 8080.
# Publishing the port to the host happens in docker-compose.yml.
EXPOSE 8080

# Start the server. JSON (exec) form makes node the main process, so it receives
# stop signals such as SIGTERM directly.
CMD ["node", "server.js"]
