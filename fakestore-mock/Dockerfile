FROM node:20-alpine
WORKDIR /app
# RUN npm i -g json-server@^0
RUN npm i -g json-server
COPY db.json /app/db.json
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
  CMD wget -qO- http://localhost:3000/products >/dev/null || exit 1
CMD [ "json-server", "--host", "0.0.0.0", "--port", "3000", "/app/db.json" ]



# FROM node:20-alpine

# # metadata (optional but useful in GHCR)
# LABEL org.opencontainers.image.title="fakestore-mock" \
#       org.opencontainers.image.description="Mock FakeStore API (json-server)" \
#       org.opencontainers.image.source="https://github.com/<owner>/<repo>"

# WORKDIR /app

# # Install a pinned json-server version for reproducibility
# # (choose a version you trust, e.g. 0.17.4 or 1.0.0 if you’ve validated it)
# RUN npm i -g json-server@0.17.4 && npm cache clean --force

# # Copy mock data
# COPY db.json /app/db.json

# # Run as non-root
# RUN chown -R node:node /app
# USER node

# EXPOSE 3000

# # Healthcheck: ensure the endpoint responds
# HEALTHCHECK --interval=10s --timeout=3s --retries=5 \
#   CMD wget -qO- http://localhost:3000/products >/dev/null || exit 1

# # Start server
# CMD ["json-server", "--host", "0.0.0.0", "--port", "3000", "/app/db.json"]
