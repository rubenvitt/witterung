#!/usr/bin/env python3
"""Mock des Witterung-Servers für Simulator und Screenshots (nur Lesen + Orte im Speicher).

Liefert WitterungTests/Fixtures/forecast.json, zeitlich auf „jetzt“ verschoben
(Stunden ab der laufenden Stunde, Nowcast ab dem laufenden 5-min-Schritt),
und echte Radar-Zeitschritte für den DWD-WMS. Aufruf: python3 -I scripts/mock-server.py [port]
"""
import json, re, sys
from datetime import datetime, timedelta, timezone, date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "WitterungTests" / "Fixtures" / "forecast.json"
BASE = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
DAY = re.compile(r"^\d{4}-\d\d-\d\d$")
places = [{"id": 1, "name": "Uelzen", "lat": 52.9656, "lon": 10.5594, "kind": "saved", "notify": True}]


def shifted(node, delta, days, nowcast_delta):
    if isinstance(node, dict):
        return {k: shifted(v, nowcast_delta if k == "nowcast" else delta, days, nowcast_delta) for k, v in node.items()}
    if isinstance(node, list):
        return [shifted(v, delta, days, nowcast_delta) for v in node]
    if isinstance(node, str) and ISO.match(node):
        t = datetime.strptime(node, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) + delta
        return t.strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(node, str) and DAY.match(node):
        return (date.fromisoformat(node) + days).isoformat()
    return node


def forecast(name, kind, place_id):
    now = datetime.now(timezone.utc)
    delta = now.replace(minute=0, second=0, microsecond=0) - BASE
    nowcast_delta = now.replace(minute=now.minute - now.minute % 5, second=0, microsecond=0) - BASE
    berlin_today = (now + timedelta(hours=1)).date()  # MEZ genügt für den Mock
    doc = shifted(json.loads(FIXTURE.read_text()), delta, berlin_today - date(2026, 11, 9), nowcast_delta)
    doc["location"].update({"id": place_id, "name": name, "kind": kind})
    doc["generated_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    return doc


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body=None):
        data = b"" if body is None else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/v1/places":
            return self.send_json(200, places)
        m = re.match(r"^/api/v1/places/(\d+)/forecast$", path)
        if m:
            place = next((p for p in places if p["id"] == int(m[1])), None)
            return self.send_json(200, forecast(place["name"], "saved", place["id"])) if place else self.send_json(404, {"error": {"code": "not_found", "message": "Ort nicht gefunden"}})
        if path == "/api/v1/forecast":
            return self.send_json(200, forecast("Uelzen", "current", None))
        if path == "/api/v1/radar":
            now = datetime.now(timezone.utc)
            start = now.replace(minute=now.minute - now.minute % 5, second=0, microsecond=0) - timedelta(hours=2)
            frames = [(start + timedelta(minutes=5 * i)).strftime("%Y-%m-%dT%H:%M:%SZ") for i in range(49)]
            return self.send_json(200, {"wms": "https://maps.dwd.de/geoserver/dwd/wms", "layer": "dwd:Radar_rv_product_1x1km_ger", "frames": frames})
        self.send_json(404, {"error": {"code": "not_found", "message": path}})

    def do_POST(self):
        if self.path == "/api/v1/places":
            b = self.body()
            place = {"id": max([p["id"] for p in places] + [0]) + 1, "name": b["name"], "lat": b["lat"], "lon": b["lon"], "kind": "saved", "notify": False}
            places.append(place)
            return self.send_json(201, place)
        self.send_json(404, {"error": {"code": "not_found", "message": self.path}})

    def do_PATCH(self):
        m = re.match(r"^/api/v1/places/(\d+)$", self.path)
        place = m and next((p for p in places if p["id"] == int(m[1])), None)
        if not place:
            return self.send_json(404, {"error": {"code": "not_found", "message": "Ort nicht gefunden"}})
        b = self.body()
        place.update({k: b[k] for k in ("name", "notify") if k in b})
        if "position" in b:
            places.remove(place)
            places.insert(b["position"], place)
        self.send_json(200, place)

    def do_DELETE(self):
        m = re.match(r"^/api/v1/places/(\d+)$", self.path)
        places[:] = [p for p in places if not m or p["id"] != int(m[1])]
        self.send_json(204)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    print(f"Mock auf http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
