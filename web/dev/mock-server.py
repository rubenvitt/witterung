#!/usr/bin/env python3
"""Mock server for the web app: serves web/ exactly like the Rust server
(/ -> index.html, /assets/<file> -> web/assets/<file>) plus every endpoint of
docs/api.md with in-memory data. Sends the production CSP on every response.

    python3 web/dev/mock-server.py [--port 8765] [--unauth]

--unauth starts logged out (API answers 401, /auth/login logs in and redirects).
Timestamps in mock-forecast.json are shifted to "now", so the nowcast always
shows rain in about 25 minutes.
"""
import argparse
import copy
import json
import mimetypes
import re
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

WEB = Path(__file__).resolve().parent.parent
FORECAST = json.loads((WEB / "dev" / "mock-forecast.json").read_text(encoding="utf-8"))
CSP = ("default-src 'self'; img-src 'self' data: https://maps.dwd.de https://*.tile.openstreetmap.org; "
       "connect-src 'self'")
TYPES = {".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".html": "text/html",
         ".png": "image/png", ".txt": "text/plain"}
BERLIN = ZoneInfo("Europe/Berlin")
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
DATE = re.compile(r"^\d{4}-\d\d-\d\d$")

lock = threading.Lock()
state = {
    "authed": True,
    "next_id": 4,
    "places": [
        {"id": 1, "name": "Uelzen", "lat": 52.9656, "lon": 10.5594, "kind": "saved", "notify": True},
        {"id": 2, "name": "Hamburg", "lat": 53.5511, "lon": 9.9937, "kind": "saved", "notify": False},
        {"id": 3, "name": "Hannover", "lat": 52.3759, "lon": 9.732, "kind": "saved", "notify": False},
    ],
    "notifications": {"ntfy_url": "https://ntfy.example.org", "topic": "witterung-x7k2q9", "enabled": True,
                      "token_set": True},
    "devices": None,  # filled relative to now at startup
    "connections": None,  # filled relative to now at startup
}


def now():
    return datetime.now(timezone.utc)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def rebased_forecast():
    """Shift the recorded forecast to the present: hourly by whole hours, daily by days, the rest in 5-min steps."""
    gen = datetime.fromisoformat(FORECAST["generated_at"].replace("Z", "+00:00"))
    n = now()
    fine = timedelta(minutes=5 * round((n - gen).total_seconds() / 300))
    hour = n.replace(minute=0, second=0, microsecond=0) - gen.replace(minute=0, second=0, microsecond=0)
    day = n.astimezone(BERLIN).date() - gen.astimezone(BERLIN).date()

    def walk(v, delta, days):
        if isinstance(v, dict):
            return {k: walk(x, delta, days) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x, delta, days) for x in v]
        if isinstance(v, str) and ISO.match(v):
            return iso(datetime.fromisoformat(v.replace("Z", "+00:00")) + delta)
        if isinstance(v, str) and DATE.match(v):
            return (datetime.fromisoformat(v) + days).date().isoformat()
        return v

    fc = copy.deepcopy(FORECAST)
    out = {k: walk(v, fine, day) for k, v in fc.items() if k not in ("hourly", "daily")}
    out["hourly"] = walk(fc["hourly"], hour, day)
    out["daily"] = walk(fc["daily"], day, day)
    out["now"]["forecast"] = out["hourly"][0]["consensus"]
    return out


def status():
    """Like the real server: timestamps in ms, Bright Sky feeds share the quota account "bright_sky"."""
    n = now()
    ms = lambda d: int(d.timestamp() * 1000)
    def row(provider, ok, ago, interval, used, limit, period, account=None, error=None):
        return {"provider": provider, "configured": True, "ok": ok, "last_success_at": ms(n - ago), "error": error,
                "interval_s": interval, "quota": {"used": used, "limit": limit, "period": period},
                "quota_account": account or provider}
    m = lambda x: timedelta(minutes=x)
    return {"providers": [
        row("open_meteo", True, m(31), 3600, 412.8, 5000, "day"),
        row("bright_sky", True, m(4), 3600, 2210, 3000, "day"),
        row("weatherkit", True, m(8), 900, 3104, 250000, "month"),
        row("pirate_weather", False, m(312), 3600, 1840, 5000, "month", error="HTTP 503 Service Unavailable"),
        row("dwd_observation", True, m(6), 600, 2210, 3000, "day", "bright_sky"),
        row("dwd_alerts", True, m(2), 300, 2210, 3000, "day", "bright_sky"),
        row("dwd_radar", True, m(3), 300, 2210, 3000, "day", "bright_sky"),
    ]}


def radar():
    n = now()
    # Like the server's fallback: the last analysis is about 10 min old, 24 frames back, 24 ahead.
    last = n.replace(second=0, microsecond=0) - timedelta(minutes=n.minute % 5 + 10)
    return {"wms": "https://maps.dwd.de/geoserver/dwd/wms", "layer": "dwd:Radar_rv_product_1x1km_ger",
            "frames": [iso(last + timedelta(minutes=5 * (i - 24))) for i in range(49)],
            "now_index": 24, "attribution": "Radar: Deutscher Wetterdienst"}


class Handler(BaseHTTPRequestHandler):
    server_version = "witterung-mock"

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}")

    # --- responses ---
    def send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if body or code not in (204, 303):
            self.send_header("Content-Type", f"{ctype}; charset=utf-8" if ctype.startswith(("text", "application/json")) else ctype)
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def json(self, code, obj):
        self.send(code, json.dumps(obj, ensure_ascii=False).encode())

    def error(self, code, msg):
        self.json(code, {"error": {"code": HTTPStatus(code).phrase.lower().replace(" ", "_"), "message": msg}})

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"null")
        except json.JSONDecodeError:
            return None

    # --- routing ---
    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if method == "GET" and path == "/":
            return self.static(WEB / "index.html")
        if method == "GET" and path.startswith("/assets/"):
            name = path[len("/assets/"):]
            if "/" in name or name.startswith("."):
                return self.error(404, "Nicht gefunden")
            return self.static(WEB / "assets" / name)
        if path == "/health":
            return self.json(200, {"status": "degraded", "version": "mock", "sources": [
                {k: p[k] for k in ("provider", "configured", "ok", "last_success_at", "error")} for p in status()["providers"]]})
        if method == "GET" and path == "/auth/login":
            target = (query.get("return_to") or ["/"])[0]
            if not target.startswith("/") or target.startswith("//"):
                target = "/"
            state["authed"] = True
            return self.send(303, extra={"Location": target})

        # Cookie writes need the client header (CSRF protection, as in the real server).
        if method != "GET" and self.headers.get("X-Witterung-Client") != "web":
            return self.error(403, "Header X-Witterung-Client fehlt (Schutz vor Cross-Site-Anfragen)")
        if method == "POST" and path == "/auth/logout":
            state["authed"] = False
            return self.send(204)
        if not path.startswith("/api/v1/"):
            return self.error(404, "Nicht gefunden")
        if not state["authed"]:
            return self.error(401, "Nicht angemeldet")
        with lock:
            return self.api(method, path[len("/api/v1"):], query)

    def api(self, method, path, query):
        places = state["places"]
        find = lambda pid: next((p for p in places if str(p["id"]) == pid), None)

        if path == "/places" and method == "GET":
            return self.json(200, places)
        if path == "/places" and method == "POST":
            b = self.body() or {}
            name = str(b.get("name") or "").strip()
            lat, lon = b.get("lat"), b.get("lon")
            if not name or not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)) \
                    or not -90 <= lat <= 90 or not -180 <= lon <= 180:
                return self.error(400, "Name, Breite (−90…90) und Länge (−180…180) angeben")
            place = {"id": state["next_id"], "name": name, "lat": lat, "lon": lon, "kind": "saved", "notify": False}
            state["next_id"] += 1
            places.append(place)
            return self.json(201, place)
        m = re.fullmatch(r"/places/(\d+)", path)
        if m:
            place = find(m[1])
            if not place:
                return self.error(404, "Ort nicht gefunden")
            if method == "PATCH":
                b = self.body() or {}
                if "name" in b:
                    if not str(b["name"]).strip():
                        return self.error(400, "Name darf nicht leer sein")
                    place["name"] = str(b["name"]).strip()
                if "notify" in b:
                    place["notify"] = bool(b["notify"])
                if "position" in b:
                    places.remove(place)
                    places.insert(max(0, min(len(places), int(b["position"]))), place)
                return self.json(200, place)
            if method == "DELETE":
                places.remove(place)
                return self.send(204)
        m = re.fullmatch(r"/places/(\d+)/forecast", path)
        if m and method == "GET":
            place = find(m[1])
            if not place:
                return self.error(404, "Ort nicht gefunden")
            time.sleep(0.2)
            fc = rebased_forecast()
            fc["location"] = {k: place[k] for k in ("id", "name", "lat", "lon", "kind")}
            return self.json(200, fc)
        if path == "/forecast" and method == "GET":
            try:
                lat, lon = float(query["lat"][0]), float(query["lon"][0])
            except (KeyError, ValueError):
                return self.error(400, "lat und lon angeben")
            time.sleep(0.8)
            fc = rebased_forecast()
            fc["location"] = {"id": None, "name": "Aktueller Standort", "lat": round(lat / 0.02) * 0.02,
                              "lon": round(lon / 0.02) * 0.02, "kind": "current"}
            return self.json(200, fc)
        if path == "/radar" and method == "GET":
            return self.json(200, radar())
        if path == "/status" and method == "GET":
            return self.json(200, status())
        if path == "/settings/notifications":
            cfg = state["notifications"]
            if method == "GET":
                return self.json(200, cfg)
            if method == "PUT":
                b = self.body() or {}
                if not str(b.get("ntfy_url", "")).startswith("https://") or not str(b.get("topic", "")).strip():
                    return self.error(400, "ntfy-URL (https) und Topic angeben")
                cfg.update(ntfy_url=b["ntfy_url"], topic=b["topic"].strip(), enabled=bool(b.get("enabled")))
                if b.get("token"):
                    cfg["token_set"] = True
                return self.json(200, cfg)
        if path == "/settings/notifications/test" and method == "POST":
            return self.send(204)
        if path == "/devices" and method == "GET":
            return self.json(200, state["devices"])
        if path == "/devices" and method == "POST":
            name = str((self.body() or {}).get("name", "")).strip()
            if not 1 <= len(name) <= 60:
                return self.error(400, "Name: 1 bis 60 Zeichen")
            dev = {"id": max([d["id"] for d in state["devices"]] + [0]) + 1, "name": name,
                   "created_at": iso(now()), "last_used_at": None}
            state["devices"].append(dev)
            return self.json(201, {"token": "wt_mock" + secrets.token_urlsafe(24), "device_id": dev["id"]})
        if path == "/connections" and method == "GET":
            return self.json(200, state["connections"])
        m = re.fullmatch(r"/connections/([A-Za-z0-9_-]+)", path)
        if m and method == "DELETE":
            before = len(state["connections"])
            state["connections"] = [c for c in state["connections"] if c["id"] != m[1]]
            return self.send(204) if len(state["connections"]) < before else self.error(404, "nicht gefunden")
        m = re.fullmatch(r"/devices/(\d+)", path)
        if m and method == "DELETE":
            before = len(state["devices"])
            state["devices"] = [d for d in state["devices"] if str(d["id"]) != m[1]]
            return self.send(204) if len(state["devices"]) < before else self.error(404, "Gerät nicht gefunden")
        return self.error(404, "Nicht gefunden")

    def static(self, file):
        if not file.is_file():
            return self.error(404, "Nicht gefunden")
        ctype = TYPES.get(file.suffix) or mimetypes.guess_type(file.name)[0] or "application/octet-stream"
        self.send(200, file.read_bytes(), ctype)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--unauth", action="store_true")
    args = ap.parse_args()
    state["authed"] = not args.unauth
    n = now()
    state["devices"] = [
        {"id": 7, "name": "iPhone", "created_at": iso(n - timedelta(days=12)), "last_used_at": iso(n - timedelta(minutes=3))},
        {"id": 9, "name": "iPad", "created_at": iso(n - timedelta(days=2)), "last_used_at": iso(n - timedelta(hours=20))},
    ]
    state["connections"] = [
        {"id": "mockclient1", "name": "Claude", "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
         "created_at": iso(n - timedelta(days=1)), "last_used_at": iso(n - timedelta(minutes=10))},
    ]
    print(f"Witterung-Mock: http://localhost:{args.port}/")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
