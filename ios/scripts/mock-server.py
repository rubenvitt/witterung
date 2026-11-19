#!/usr/bin/env python3
"""Mock des Witterung-Servers für Simulator und Screenshots (nur Lesen + Orte im Speicher).

Liefert WitterungTests/Fixtures/forecast.json, zeitlich auf „jetzt“ verschoben
(Stunden ab der laufenden Stunde, Nowcast ab dem laufenden 5-min-Schritt),
und echte Radar-Zeitschritte; Radar- und Warnungsbilder holt er wie der Server beim DWD
(dauert pro Bild 5–30 s, danach aus dem Speicher). Aufruf: python3 -I scripts/mock-server.py [port]
"""
import json, re, sys, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone, date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "WitterungTests" / "Fixtures" / "forecast.json"
BASE = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
DAY = re.compile(r"^\d{4}-\d\d-\d\d$")
GEOSERVER = "https://maps.dwd.de/geoserver/dwd/wms"
BBOX = [222638.98, 5780349.22, 2003750.83, 7558415.66]  # wie server/src/radar.rs
images = {}
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


def dwd_image(layer, time=None):
    key = (layer, time)
    if key not in images:
        q = {"SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": layer, "STYLES": "",
             "CRS": "EPSG:3857", "BBOX": ",".join(f"{v:.2f}" for v in BBOX), "WIDTH": "1024", "HEIGHT": "1022",
             "FORMAT": "image/png", "TRANSPARENT": "true"}
        if time:
            q["TIME"] = time
        with urllib.request.urlopen(f"{GEOSERVER}?{urllib.parse.urlencode(q)}", timeout=60) as r:
            if not r.headers.get("Content-Type", "").startswith("image/png"):
                return None
            images[key] = r.read()
    return images[key]


class Handler(BaseHTTPRequestHandler):
    def send_png(self, data):
        if data is None:
            return self.send_json(502, {"error": {"code": "upstream", "message": "DWD liefert kein Bild"}})
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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
            # Wie der Fallback des Servers: Die letzte Analyse ist etwa 10 min alt.
            now = datetime.now(timezone.utc)
            last = now.replace(minute=now.minute - now.minute % 5, second=0, microsecond=0) - timedelta(minutes=10)
            frames = [(last + timedelta(minutes=5 * (i - 24))).strftime("%Y-%m-%dT%H:%M:%SZ") for i in range(49)]
            return self.send_json(200, {"wms": GEOSERVER, "layer": "dwd:Radar_rv_product_1x1km_ger", "frames": frames, "now_index": 24,
                                        "image": {"bbox": BBOX, "crs": "EPSG:3857", "width": 1024, "height": 1022,
                                                  "frame": "/api/v1/radar/frames/{unix}", "warnings": "/api/v1/radar/warnings"}})
        m = re.match(r"^/api/v1/radar/frames/(\d+)$", path)
        if m:
            t = datetime.fromtimestamp(int(m[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            return self.send_png(dwd_image("dwd:Radar_rv_product_1x1km_ger", t))
        if path == "/api/v1/radar/warnings":
            return self.send_png(dwd_image("dwd:Warnungen_Gemeinden_vereinigt"))
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
