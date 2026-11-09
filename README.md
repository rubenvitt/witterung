# Witterung

Persönliche Wetter-App: ein Aggregator auf dem Homelab kombiniert Apple WeatherKit,
Open-Meteo (mehrere Modelle), Bright Sky/DWD und Pirate Weather und beliefert eine
SwiftUI-App mit Widgets.

Stand: **M1** (vier Quellen-Adapter, Kontingente, Poller, Rohdaten-API).
Format und Quellen: [docs/schema.md](docs/schema.md).
Plan und Meilensteine: [docs/plan.md](docs/plan.md), Stack-Entscheidung:
[ADR 0001](docs/adr/0001-backend-stack.md).

```
iPhone-App / Widget ─┐
Browser ─────────────┼─► Traefik ─► witterung (Rust, SQLite) ─► WeatherKit, Open-Meteo,
                     │   (TLS)       Pocket-ID-Login              Bright Sky/DWD, Pirate Weather
```

## Lokal entwickeln

```fish
cd server
set -x WITTERUNG_DEV_AUTH true   # Anmeldung ohne Pocket ID, nur über localhost
cargo run
# http://localhost:8080 – /health ist öffentlich, /api/v1/me braucht Anmeldung
```

Tests: `cargo test` (der OIDC-Ablauf läuft gegen einen lokalen Mock-Anbieter mit frisch
erzeugten RSA-Schlüsseln).

## Betrieb auf dem Homelab

1. **Pocket ID:** OIDC-Client anlegen, Callback `https://witterung.rubeen.dev/auth/callback`,
   vertraulicher Client (mit Secret).
2. **DNS:** `witterung.rubeen.dev` muss auf den Server zeigen.
3. **Stack:** `deploy/docker-compose.yml` nach `~/server/witterung/` kopieren, in `server.sh` (`SERVICES`) registrieren, daneben `.env` aus
   `deploy/.env.example` befüllen und `data/` anlegen (`sudo chown 10001:10001 data`).
   Das Image ist privat: einmal `docker login ghcr.io -u rubenvitt`.
4. `docker compose up -d`, dann `https://witterung.rubeen.dev` öffnen und anmelden.

Jeder Push auf `main` baut `ghcr.io/rubenvitt/witterung` für amd64 und arm64 und legt ein
GitHub-Deployment an. Ausgerollt wird es nur, wenn Witterung im `deploy-agent` eingetragen
ist (`~/server/deploy-agent/targets`); sonst von Hand: `~/server/server.sh update witterung`.

### Konfiguration

Per Env nur der Bootstrap; Orte und alles Weitere werden in der App eingestellt.

| Variable | Zweck |
|---|---|
| `WITTERUNG_PUBLIC_URL` | öffentliche Adresse (Cookies, OIDC-Callback) |
| `WITTERUNG_BIND` | Adresse im Container, Standard `0.0.0.0:8080` |
| `WITTERUNG_DATA_DIR` | SQLite-Verzeichnis, Standard `./data` |
| `WITTERUNG_OIDC_ISSUER`, `_CLIENT_ID`, `_CLIENT_SECRET` | Pocket ID |
| `WITTERUNG_OIDC_ALLOWED_EMAIL` oder `_ALLOWED_SUBJECT` | die eine Person, die sich anmelden darf |
| `WITTERUNG_SESSION_SECRET` | ≥ 32 Zeichen, HMAC-Schlüssel für Sitzungen |
| `WITTERUNG_DEV_AUTH` | nur lokal: Anmeldung ohne Pocket ID über localhost |
| `WITTERUNG_WEATHERKIT_KEY_FILE` (oder `_KEY`), `_KEY_ID`, `_TEAM_ID`, `_SERVICE_ID` | WeatherKit, alle vier oder keiner |
| `WITTERUNG_PIRATE_WEATHER_KEY` (oder `_KEY_FILE`) | Pirate Weather |

Open-Meteo und Bright Sky laufen ohne Zugang. Für WeatherKit den `.p8`-Schlüssel nach
`~/server/witterung/secrets/weatherkit.p8` legen (lesbar für uid 10001), in der Compose-Datei
`./secrets/weatherkit.p8:/run/secrets/weatherkit.p8:ro` einhängen und die vier Variablen
setzen. Ein kaputter Schlüssel lässt den Server gar nicht erst starten.

Orte anlegen (bis die App da ist), mit Sitzungs-Cookie aus dem Browser:

```fish
curl -X POST https://witterung.rubeen.dev/api/v1/places -H 'X-Witterung-Client: cli' \
  -H 'Content-Type: application/json' -b "witterung_session=…" \
  -d '{"name":"Uelzen","lat":52.9656,"lon":10.5594}'
```
