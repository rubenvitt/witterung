#!/usr/bin/env python3
"""Writes mock-forecast.json: a realistic November forecast for Uelzen per docs/api.md.

A cold front passes in the afternoon (rain from 12:25 UTC, gusts, DWD warning),
then showery and cooler. pirate_weather fails, bright_sky:mosmix is stale.
Consensus = median per value, like the server. Deterministic (fixed seed).
"""
import json
import math
import random
import statistics
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

random.seed(7)
BASE = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)  # 13:00 in Uelzen
UTC_OFFSET = timedelta(hours=1)  # CET in November
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")

SOURCES = {  # source: (provider, hours, days, bias °C)
    "open_meteo:icon_d2": ("open_meteo", 48, 2, 0.0),
    "open_meteo:icon_eu": ("open_meteo", 48, 5, 0.3),
    "open_meteo:ecmwf_ifs": ("open_meteo", 48, 10, -0.2),
    "open_meteo:gfs": ("open_meteo", 48, 10, 0.9),
    "bright_sky:mosmix": ("bright_sky", 48, 9, -0.4),
    "weatherkit": ("weatherkit", 48, 10, 0.2),
    "pirate_weather": ("pirate_weather", 0, 0, 0.0),  # failed
}


def base_temp(t):
    local_h = (t + UTC_OFFSET).hour + (t + UTC_OFFSET).minute / 60
    days = (t - BASE).total_seconds() / 86400
    diurnal = 2.4 * math.cos((local_h - 14.5) / 24 * 2 * math.pi)
    front = -2.2 / (1 + math.exp(-(days - 0.25) * 10))  # cooler after the front
    return 6.8 + diurnal + front - 0.25 * days


def base_precip(i):
    front = {0: 0.4, 1: 0.6, 2: 1.8, 3: 2.4, 4: 1.1, 5: 0.4, 6: 0.1}
    if i in front:
        return front[i]
    if 26 <= i <= 30:  # showers tomorrow afternoon
        return [0.2, 0.6, 0.9, 0.3, 0.1][i - 26]
    return 0.0


def base_wind(i):
    return 16 + 18 * math.exp(-((i - 3) / 4) ** 2) + 4 * math.sin(i / 5)


def condition(precip, cloud, gust):
    if precip >= 7.6:
        return "heavy_rain"
    if precip >= 0.5:
        return "rain"
    if precip >= 0.1:
        return "drizzle"
    if gust >= 60:
        return "wind"
    if cloud >= 85:
        return "cloudy"
    if cloud >= 30:
        return "partly_cloudy"
    return "clear"


def is_day(t):
    local_h = (t + UTC_OFFSET).hour
    return 7 <= local_h < 16


def r1(v):
    return round(v, 1)


def hour_point(t, i, bias, rnd):
    temp = base_temp(t) + bias + rnd.gauss(0, 0.5)
    precip = max(0.0, base_precip(i) * rnd.uniform(0.5, 1.5) + (rnd.uniform(-0.15, 0.25) if base_precip(i) else 0))
    precip = 0.0 if precip < 0.05 else r1(precip)
    wind = max(3, base_wind(i) + rnd.gauss(0, 3))
    gust = wind * rnd.uniform(1.6, 1.9)
    cloud = min(100, max(0, (95 if base_precip(i) or 0 < i < 9 else 55 + 30 * math.sin(i / 6)) + rnd.gauss(0, 8)))
    return {
        "at": iso(t),
        "temp_c": r1(temp),
        "feels_like_c": r1(temp - wind / 10 - 0.8),
        "precip_mm": precip,
        "precip_prob_pct": min(100, round(precip * 45 + rnd.uniform(0, 15))) if precip else round(rnd.uniform(0, 12)),
        "wind_kmh": r1(wind),
        "gust_kmh": r1(gust),
        "wind_dir_deg": round((215 + 25 * math.sin(i / 9) + rnd.gauss(0, 8)) % 360),
        "cloud_pct": round(cloud),
        "humidity_pct": round(min(100, 80 + (12 if precip else 0) + rnd.gauss(0, 3))),
        "pressure_hpa": r1(1012 - 9 * math.exp(-((i - 4) / 6) ** 2) + i * 0.12 + rnd.gauss(0, 0.4)),
        "condition": condition(precip, cloud, gust),
        "is_day": is_day(t),
    }


def day_point(d, j, bias, rnd):
    tmin = 4.5 - 0.35 * j + 1.6 * math.sin(j / 2.2) + bias + rnd.gauss(0, 0.6 + j * 0.12)
    tmax = tmin + 4.2 + rnd.gauss(0, 0.5 + j * 0.1)
    rain_days = {0: 7.5, 1: 2.0, 3: 0.4, 4: 5.5, 5: 3.0, 8: 1.2}
    precip = max(0.0, rain_days.get(j, 0.0) * rnd.uniform(0.4, 1.6) + rnd.uniform(-0.3, 0.3))
    precip = 0.0 if precip < 0.1 else r1(precip)
    wind = 22 + 14 * (j == 0) + rnd.gauss(0, 4)
    cond = "rain" if precip >= 1 else ("partly_cloudy" if rnd.random() < 0.5 else "cloudy")
    sunrise = datetime(d.year, d.month, d.day, 6, 21, tzinfo=timezone.utc) + timedelta(minutes=2 * j)
    sunset = datetime(d.year, d.month, d.day, 15, 33, tzinfo=timezone.utc) - timedelta(minutes=1.5 * j)
    return {
        "date": d.isoformat(),
        "temp_min_c": r1(tmin),
        "temp_max_c": r1(tmax),
        "precip_mm": precip,
        "precip_prob_pct": min(100, round(precip * 12 + rnd.uniform(5, 20))),
        "wind_max_kmh": r1(wind),
        "gust_max_kmh": r1(wind * 1.8),
        "condition": cond,
        "sunrise": iso(sunrise),
        "sunset": iso(sunset),
    }


def median_point(points, keys_num, key_time):
    out = {key_time: points[0][key_time]}
    for k in keys_num:
        vals = [p[k] for p in points if p.get(k) is not None]
        out[k] = r1(statistics.median(vals)) if vals else None
    conds = [p["condition"] for p in points]
    severity = ["clear", "partly_cloudy", "cloudy", "fog", "wind", "drizzle", "rain", "sleet", "snow", "heavy_rain", "hail", "thunderstorm"]
    out["condition"] = max(set(conds), key=lambda c: (conds.count(c), severity.index(c)))
    if "is_day" in points[0]:
        days = [p["is_day"] for p in points]
        out["is_day"] = days.count(True) >= len(days) / 2
    return out


def span(points, k):
    vals = [p[k] for p in points if p.get(k) is not None]
    return {"min": min(vals), "max": max(vals)} if vals else None


def main():
    rnds = {s: random.Random(zlib.crc32(s.encode())) for s in SOURCES}
    hourly = []
    for i in range(48):
        t = BASE + timedelta(hours=i)
        by = {s: hour_point(t, i, b, rnds[s]) for s, (_, hrs, _, b) in SOURCES.items() if i < hrs}
        pts = list(by.values())
        hourly.append({
            "at": iso(t),
            "n_sources": len(pts),
            "consensus": median_point(pts, ["temp_c", "feels_like_c", "precip_mm", "precip_prob_pct", "wind_kmh", "gust_kmh",
                                            "wind_dir_deg", "cloud_pct", "humidity_pct", "pressure_hpa"], "at"),
            "spread": {
                "temp_c": span(pts, "temp_c"), "precip_mm": span(pts, "precip_mm"), "wind_kmh": span(pts, "wind_kmh"),
                "precip_agreement_pct": round(100 * sum(p["precip_mm"] >= 0.1 for p in pts) / len(pts)),
            },
            "by_source": by,
        })

    daily = []
    today = (BASE + UTC_OFFSET).date()
    for j in range(10):
        d = today + timedelta(days=j)
        by = {s: day_point(d, j, b, rnds[s]) for s, (_, _, days, b) in SOURCES.items() if j < days}
        pts = list(by.values())
        daily.append({
            "date": d.isoformat(),
            "n_sources": len(pts),
            "consensus": median_point(pts, ["temp_min_c", "temp_max_c", "precip_mm", "precip_prob_pct", "wind_max_kmh", "gust_max_kmh"], "date")
            | {"sunrise": pts[0]["sunrise"], "sunset": pts[0]["sunset"]},
            "spread": {
                "temp_min_c": span(pts, "temp_min_c"), "temp_max_c": span(pts, "temp_max_c"), "precip_mm": span(pts, "precip_mm"),
                "precip_agreement_pct": round(100 * sum(p["precip_mm"] >= 1 for p in pts) / len(pts)),
            },
            "by_source": by,
        })

    nowcast = [0, 0, 0, 0, 0, 0.05, 0.3, 0.8, 1.6, 2.4, 3.1, 2.6, 2.2, 1.9, 2.0, 1.7, 1.4, 1.2, 1.3, 1.1, 0.9, 0.8, 0.6, 0.5]
    sources = []
    for s, (provider, _, _, _) in SOURCES.items():
        if s == "pirate_weather":
            sources.append({"source": s, "provider": provider, "ok": False, "fetched_at": iso(BASE - timedelta(hours=5, minutes=12)),
                            "stale": True, "error": "HTTP 503 Service Unavailable"})
        elif s == "bright_sky:mosmix":
            sources.append({"source": s, "provider": provider, "ok": True, "fetched_at": iso(BASE - timedelta(hours=3, minutes=40)),
                            "stale": True, "error": None})
        else:
            sources.append({"source": s, "provider": provider, "ok": True,
                            "fetched_at": iso(BASE - timedelta(minutes=8 if s == "weatherkit" else 31)), "stale": False, "error": None})

    forecast = {
        "location": {"id": 1, "name": "Uelzen", "lat": 52.9656, "lon": 10.5594, "kind": "saved"},
        "generated_at": iso(BASE + timedelta(seconds=3)),
        "sources": sources,
        "now": {
            "observed": {
                "station": "Uelzen", "distance_m": 3383, "at": iso(BASE - timedelta(minutes=10)),
                "temp_c": 7.5, "humidity_pct": 82, "wind_kmh": 24.1, "gust_kmh": 41.8, "wind_dir_deg": 205,
                "pressure_hpa": 1006.4, "precip_mm_1h": 0.0, "cloud_pct": 88, "visibility_m": 12124, "condition": "cloudy",
            },
            "forecast": hourly[0]["consensus"],
        },
        "nowcast": {
            "source": "bright_sky:radar", "at": iso(BASE - timedelta(minutes=5)),
            "points": [{"at": iso(BASE + timedelta(minutes=5 * k)), "precip_mm_h": v} for k, v in enumerate(nowcast)],
        },
        "hourly": hourly,
        "daily": daily,
        "alerts": [
            {
                "id": "2.49.0.0.276.0.DWD.PVW.1762689600000.mock-sturm",
                "severity": "moderate", "event": "STURMBÖEN",
                "headline": "Amtliche WARNUNG vor STURMBÖEN",
                "description": "Es treten Sturmböen mit Geschwindigkeiten um 65 km/h (18 m/s, 35 kn, Bft 8) aus südwestlicher Richtung auf. "
                               "In exponierten Lagen muss mit Sturmböen bis 75 km/h (21 m/s, 40 kn, Bft 9) gerechnet werden.",
                "instruction": "ACHTUNG! Hinweis auf mögliche Gefahren: Es können zum Beispiel einzelne Äste herabstürzen. "
                               "Achten Sie besonders auf herabfallende Gegenstände.",
                "onset": iso(BASE + timedelta(hours=1)), "expires": iso(BASE + timedelta(hours=9)), "source": "dwd",
            },
            {
                "id": "2.49.0.0.276.0.DWD.PVW.1762689600000.mock-wind",
                "severity": "minor", "event": "WINDBÖEN",
                "headline": "Amtliche WARNUNG vor WINDBÖEN",
                "description": "Es treten Windböen mit Geschwindigkeiten um 55 km/h (15 m/s, 30 kn, Bft 7) aus westlicher Richtung auf. "
                               "In Schauernähe muss mit Sturmböen um 65 km/h (18 m/s, 35 kn, Bft 8) gerechnet werden.",
                "instruction": None,
                "onset": iso(BASE + timedelta(hours=25)), "expires": iso(BASE + timedelta(hours=31)), "source": "dwd",
            },
        ],
        "attribution": [
            {"source": "open_meteo", "text": "Wetterdaten von Open-Meteo.com (CC BY 4.0)", "url": "https://open-meteo.com/"},
            {"source": "bright_sky", "text": "Quelle: Deutscher Wetterdienst (DWD), abgerufen über Bright Sky", "url": "https://www.dwd.de/"},
            {"source": "weatherkit", "text": "Apple Weather", "url": "https://developer.apple.com/weatherkit/data-source-attribution/"},
            {"source": "pirate_weather", "text": "Pirate Weather", "url": "https://pirateweather.net/"},
        ],
    }
    out = Path(__file__).with_name("mock-forecast.json")
    out.write_text(json.dumps(forecast, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
