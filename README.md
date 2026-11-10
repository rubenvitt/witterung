# Witterung

Persönliche Wetter-App: ein Aggregator auf dem Homelab kombiniert Apple WeatherKit,
Open-Meteo (mehrere Modelle), Bright Sky/DWD und Pirate Weather und beliefert eine
SwiftUI-App mit Widgets.

Stand: **M0–M7 umgesetzt**: Server (Quellen, Konsens, Jetzt/Nowcast/Warnungen, Push über ntfy,
Geräte-Anmeldung), iOS-App mit Widgets und Radarkarte ([ios/README.md](ios/README.md)) und
Web-App unter `/` ([web/README.md](web/README.md)). WeatherKit und Pirate Weather warten auf ihre
Zugänge.
Dazu ein MCP-Server unter `/mcp`, damit Claude Vorhersagen, Warnungen und Orte abfragen kann
(siehe [MCP verbinden](#mcp-verbinden)).
API: [docs/api.md](docs/api.md), Format und Quellen: [docs/schema.md](docs/schema.md).
Plan und Meilensteine: [docs/plan.md](docs/plan.md), Stack-Entscheidung:
[ADR 0001](docs/adr/0001-backend-stack.md).

```
iPhone-App / Widget ─┐
Browser ─────────────┤
Claude (MCP) ────────┼─► Traefik ─► witterung (Rust, SQLite) ─► WeatherKit, Open-Meteo,
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

Orte und Push lassen sich in der App bzw. Web-App einstellen; ohne Oberfläche geht es auf
dem Server per `docker exec`:

```fish
docker exec witterung witterung place-add Uelzen 52.9656 10.5594 notify
# Token für einen Client ohne Browser (z. B. die Mac-Menüleiste), steht nur einmal auf stdout:
docker exec witterung witterung device-add Mac-Leiste
# ntfy (läuft als eigener Dienst ~/server/ntfy, Zugangsdaten dort in credentials.txt):
grep '^token:' ~/server/ntfy/credentials.txt | cut -d' ' -f2 | tr -d '\n' \
  | docker exec -i witterung witterung notify-set http://ntfy:80 witterung
```

Push kommt über die ntfy-App (Server `https://ntfy.rubeen.dev`, Topic `witterung`, Konto
`iphone` aus `credentials.txt`): neue DWD-Warnung ab Stufe 2 und Regen in < 30 min laut Radar,
für Orte mit `notify`. Die Datenbank wird nachts nach `data/backups/` gesichert (7 Tage).

## MCP verbinden

Endpunkt: `https://witterung.rubeen.dev/mcp` (Streamable HTTP). Werkzeuge: `list_places`,
`get_forecast`, `get_alerts`, `get_source_status`, `create_place`, `update_place`, `delete_place`
(Details in [docs/api.md](docs/api.md#mcp-agenten)).

**claude.ai** (und die Claude-Apps): Einstellungen → Connectoren → Eigenen Connector hinzufügen,
URL `https://witterung.rubeen.dev/mcp`, sonst nichts eintragen. claude.ai registriert sich selbst
(OAuth), schickt dich über die Pocket-ID-Anmeldung auf eine Freigabeseite, und nach „Erlauben“
steht der Connector bereit. Trennen geht in der Web-App unter Verwaltung → Verbundene Apps.

**Claude Code:** Mit einem Geräte-Token (Web-App unter Verwaltung → Geräte oder
`docker exec witterung witterung device-add Claude-Code`):

```sh
claude mcp add --transport http --scope user witterung https://witterung.rubeen.dev/mcp \
  --header "Authorization: Bearer wt_…"
```

Ohne Anmeldung erreichbar sind dafür nur die OAuth-Metadaten unter `/.well-known/*` und die
Endpunkte unter `/oauth/*` (Registrierung begrenzt; Token gibt es nur über eine Freigabe mit
Sitzung). Wer vor Traefik eine IP-Allowlist oder Forward-Auth schaltet, muss `/mcp`,
`/.well-known/*` und `/oauth/*` ausnehmen, sonst erreicht claude.ai den Connector nicht.
