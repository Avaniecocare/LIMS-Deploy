# S3-compatible store for local development and script checks only. Not for production.
FROM node:26-alpine
WORKDIR /srv
RUN npm init -y >/dev/null && npm install --omit=dev s3rver@3.7.1 >/dev/null
COPY server.mjs ./
EXPOSE 9000
ENTRYPOINT ["node", "server.mjs"]
