# nginx — homelab landing page

Self-contained nginx stack serving the homelab landing page. No build step,
no dependencies — plain HTML/CSS/JS. Mirrors `~/Source/nginx` on `node-one`.

## Structure

```
infra/nginx/
├── docker-compose.yml  # the stack (mounts ./html and ./conf.d)
├── conf.d/
│   └── default.conf    # server block: listen 80, root /usr/share/nginx/html
└── html/               # document root
    ├── index.html      # the page
    ├── favicon.svg
    └── assets/
        ├── css/style.css   # all styles (light + dark theme)
        ├── js/main.js      # theme toggle + footer year
        └── img/logo.svg
```

## Editing

- **Service cards:** in `html/index.html`, copy/edit an `<a class="card">`
  block. Change the `href`, name, description, and the status dot
  (`dot-on` = online, `dot-off` = planned/offline).
- **Colors / spacing:** tweak the CSS variables at the top of
  `html/assets/css/style.css`. Both light and dark themes are defined there.

## Run it

```bash
cd infra/nginx
docker compose up -d
```

`docker-compose.yml`:

```yaml
services:
  nginx:
    image: nginx:stable
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./conf.d:/etc/nginx/conf.d:ro
```

Because it is a bind mount, edit `html/index.html` and refresh — no container
restart needed. After `git pull` on the server, changes are live too.

## Preview without Docker

```bash
cd infra/nginx/html
python3 -m http.server 8080
# open http://localhost:8080
```
