# syntax=docker/dockerfile:1
FROM node:22-alpine AS build

WORKDIR /app

COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn/releases/ ./.yarn/releases/
RUN node .yarn/releases/yarn-4.18.1.cjs install --immutable

COPY index.html vite.config.ts tsconfig*.json eslint.config.js ./
COPY public/ ./public/
COPY src/ ./src/
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
ARG API_PROXY_TARGET
ENV API_PROXY_TARGET=${API_PROXY_TARGET}
RUN node .yarn/releases/yarn-4.18.1.cjs lint \
    && node .yarn/releases/yarn-4.18.1.cjs build

FROM nginxinc/nginx-unprivileged:stable-alpine AS runtime

ARG API_PROXY_TARGET
ENV API_PROXY_TARGET=${API_PROXY_TARGET}
ENV NGINX_ENVSUBST_FILTER=API_PROXY_TARGET
USER root
RUN chown nginx:nginx /etc/nginx/conf.d
USER nginx

COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build --chown=nginx:nginx /app/dist/ /usr/share/nginx/html/

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
