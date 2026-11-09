# Fixtures

- `open_meteo/uelzen.json`: real response (09.11.2026, GFS as ncep_gfs_global), cut to 8 hours and 2 days;
  ICON-D2 nulled from hour 6 and day 2 to model the end of its horizon.
- `open_meteo/dst_end.json`: real historical forecast (ECMWF IFS) for 24.–26.10.2026,
  keys suffixed like a multi-model response.
- `bright_sky/weather.json`: real `/weather` response (09.11.2026), cut to 11.11. 00:00.
- `weatherkit/weather.json`, `pirate_weather/forecast.json`: **synthetic**, built from the
  documented schemas (no credentials yet). Replace with real responses once available.
