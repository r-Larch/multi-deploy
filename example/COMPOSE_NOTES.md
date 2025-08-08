# Compose integration with global Traefik (web network)

This project is deployed behind a global Traefik instance running on a shared Docker network named `web`.

Requirements for your compose.yml:

1) Join the `web` network

networks:
  web:
    external: true
    name: web

services:
  app:
    networks:
      - web

2) Tell Traefik which Docker network to use for routing

services:
  app:
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=web"
      - "traefik.http.routers.app.entrypoints=websecure"
      - "traefik.http.routers.app.tls.certresolver=letsencrypt"
      - "traefik.http.services.app.loadbalancer.server.port=8080"

3) Do NOT publish ports (Traefik will connect via the `web` network)

4) Ensure your app listens on the internal port you declare in labels (e.g., 8080)

5) Router rule
- Set the proper Host rule, e.g., `traefik.http.routers.app.rule=Host(`your.domain`)`

Notes
- Remove any per-project Traefik service
- Keep the rest of your stack in the same compose file
