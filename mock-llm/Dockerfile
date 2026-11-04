# Base image: Node 22 on Alpine, a small Linux image with Node preinstalled.
FROM node:22-alpine

# Set the working folder inside the image. Docker creates it if it is missing.
WORKDIR /app

# Copy only server.js from the build context (mock-llm/). The mock has no
# dependencies, so nothing else is needed at runtime.
COPY server.js ./server.js

# Switch to the built-in unprivileged "node" user. The server runs without root rights.
USER node

# Documentation only: declares that the server listens on port 8082.
# The port is not published to the host. Only other containers on the Docker network reach it.
EXPOSE 8082

# Start the server. JSON (exec) form makes node the main process, so it receives
# stop signals such as SIGTERM directly.
CMD ["node", "server.js"]
