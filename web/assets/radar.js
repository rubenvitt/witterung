// Radar map: one DWD image per frame (fetched and cached by the server) over OpenStreetMap,
// time slider with play, DWD warnings as areas.

import { api, h, icon, time, errorBox } from '/assets/util.js';
import { resolvePlace, placeBar, geolocate, HERE } from '/assets/app.js';

const GERMANY = { lat: 51.2, lon: 10.4, zoom: 6 };
const RADAR_OPACITY = 0.75;
const PLAY_MS = 700;
const WARNINGS_OPACITY = 0.5;
const WARNING_LEVELS = [
  ['Warnung', '#ffff00'], ['markant', '#faa800'], ['Unwetter', '#ff2b00'], ['extrem', '#b00064'],
];

/** Web Mercator metres → [lat, lon]. */
const toLatLon = (x, y) => {
  const r = 6378137;
  return [Math.atan(Math.sinh(y / r)) * 180 / Math.PI, x / r * 180 / Math.PI];
};

export async function renderRadar(root, param) {
  const { key, place, places } = await resolvePlace(param);
  const [radar, center] = await Promise.all([
    api('/api/v1/radar'),
    key === HERE
      ? geolocate().then((p) => ({ ...p, zoom: 8 }), () => GERMANY)
      : Promise.resolve(place ? { lat: place.lat, lon: place.lon, zoom: 8 } : GERMANY),
  ]);
  if (!root.isConnected) return undefined;
  if (!window.L) throw new Error('Kartenbibliothek nicht geladen.');
  const frames = radar.frames ?? [];
  if (!frames.length) {
    root.replaceChildren(placeBar('radar', key, places), errorBox(new Error('Keine Radarbilder verfügbar.')));
    return undefined;
  }

  const now = Date.now();
  // now_index = last analysis (server, from the DWD capabilities); later frames are forecast.
  const nowIndex = Number.isInteger(radar.now_index)
    ? Math.min(radar.now_index, frames.length - 1)
    : Math.max(0, frames.findLastIndex((f) => new Date(f) <= now));
  let current = nowIndex;

  const mapEl = h('div', { class: 'map', role: 'region', 'aria-label': 'Radarkarte' });
  const label = h('output', { class: 'frame-label', 'aria-live': 'off' });
  const loading = h('span', { class: 'muted small' });
  const warningsBox = h('input', { type: 'checkbox', checked: true });
  const slider = h('input', {
    type: 'range', min: '0', max: String(frames.length - 1), step: '1', value: String(current),
    id: 'radar-time', 'aria-describedby': 'radar-hint',
  });
  const playBtn = h('button', { type: 'button', class: 'btn btn-icon', 'aria-label': 'Abspielen' }, icon('play'));
  const past = h('span', { class: 'timebar-past' });
  past.style.width = `${(nowIndex / (frames.length - 1 || 1)) * 100}%`;

  root.replaceChildren(
    placeBar('radar', key, places),
    h('section', { class: 'card radar-card', 'aria-labelledby': 'radar-h' },
      h('h1', { id: 'radar-h', class: 'visually-hidden' }, 'Regenradar'),
      mapEl,
      h('div', { class: 'radar-controls' },
        playBtn,
        h('div', { class: 'timeline' },
          h('label', { for: 'radar-time', class: 'visually-hidden' }, 'Zeitpunkt'),
          h('div', { class: 'timebar', 'aria-hidden': 'true' }, past),
          slider,
          h('div', { class: 'timeline-labels', 'aria-hidden': 'true' },
            h('span', null, time(frames[0])),
            h('span', null, 'jetzt'),
            h('span', null, time(frames[frames.length - 1])))),
        label),
      h('div', { class: 'radar-options' },
        h('label', null, warningsBox, ' Warnungen'),
        h('span', { class: 'legend', 'aria-hidden': 'true' },
          ...WARNING_LEVELS.map(([name, color]) => h('span', { class: 'key', style: `--key:${color}` }, name))),
        loading),
      h('p', { id: 'radar-hint', class: 'muted small' },
        'Dunkler Teil der Zeitleiste: gemessen, heller Teil: Vorhersage (Nowcast). Bilder: DWD-Radarkomposit RV, 5-Minuten-Schritte.'),
      h('details', { class: 'table-details' },
        h('summary', null, 'Legende'),
        h('img', {
          class: 'radar-legend',
          alt: 'Farbskala der Niederschlagsintensität',
          src: `${radar.wms}?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetLegendGraphic&FORMAT=image/png&LAYER=${encodeURIComponent(radar.layer)}`,
        }))));

  const map = window.L.map(mapEl, { zoomSnap: 0.5 }).setView([center.lat, center.lon], center.zoom);
  map.attributionControl.setPrefix(false);
  window.L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    subdomains: 'abc',
    maxZoom: 18,
    className: 'osm-tiles',
    attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>-Mitwirkende',
  }).addTo(map);
  map.attributionControl.addAttribution('Radar und Warnungen: <a href="https://www.dwd.de/">Deutscher Wetterdienst</a>');
  if (center !== GERMANY) {
    window.L.circleMarker([center.lat, center.lon], { radius: 6, weight: 2, className: 'place-marker' }).addTo(map);
  }

  // One image overlay per frame, created on demand: switching opacity does not flicker.
  // The server answers with one image for all of Germany (the DWD needs 5–30 s per request,
  // so 49 frames as tiles never finished); older servers without `image` fall back to WMS tiles.
  const img = radar.image;
  const bounds = img && [toLatLon(img.bbox[0], img.bbox[1]), toLatLon(img.bbox[2], img.bbox[3])];
  const layers = new Map();
  const loaded = new Set();
  const updateLoading = () => {
    loading.textContent = loaded.size < frames.length ? `Radarbilder: ${loaded.size} von ${frames.length}` : '';
  };
  const layerFor = (i) => {
    if (!layers.has(i)) {
      const layer = img
        ? window.L.imageOverlay(img.frame.replace('{unix}', String(Math.round(new Date(frames[i]) / 1000))), bounds,
          { opacity: 0, zIndex: 10, className: 'radar-image' })
        : window.L.tileLayer.wms(radar.wms, {
          layers: radar.layer, version: '1.3.0', format: 'image/png', transparent: true,
          TIME: frames[i], opacity: 0, zIndex: 10,
        });
      layer.on('load', () => { loaded.add(i); updateLoading(); });
      layers.set(i, layer.addTo(map));
    }
    return layers.get(i);
  };

  if (img) {
    const warnings = window.L.imageOverlay(img.warnings, bounds, { opacity: WARNINGS_OPACITY, zIndex: 5 });
    const toggleWarnings = () => (warningsBox.checked ? warnings.addTo(map) : warnings.remove());
    warningsBox.addEventListener('change', toggleWarnings);
    toggleWarnings();
    // Load everything up front, nearest to "now" first; the server keeps the images.
    for (let d = 0; d < frames.length; d += 1) {
      if (nowIndex + d < frames.length) layerFor(nowIndex + d);
      if (d > 0 && nowIndex - d >= 0) layerFor(nowIndex - d);
    }
  } else {
    warningsBox.closest('.radar-options').hidden = true;
  }
  updateLoading();

  const show = (i) => {
    current = i;
    for (const [j, layer] of layers) if (j !== i) layer.setOpacity(0);
    layerFor(i).setOpacity(RADAR_OPACITY);
    slider.value = String(i);
    const kind = i <= nowIndex ? 'gemessen' : 'Vorhersage';
    label.textContent = `${time(frames[i])} Uhr · ${kind}`;
    label.classList.toggle('is-forecast', i > nowIndex);
    slider.setAttribute('aria-valuetext', label.textContent);
  };

  let timer = null;
  const stop = () => {
    clearInterval(timer);
    timer = null;
    playBtn.replaceChildren(icon('play'));
    playBtn.setAttribute('aria-label', 'Abspielen');
  };
  const play = () => {
    playBtn.replaceChildren(icon('pause'));
    playBtn.setAttribute('aria-label', 'Anhalten');
    timer = setInterval(() => {
      // Skip frames that have not arrived yet instead of showing an empty map.
      let next = (current + 1) % frames.length;
      for (let k = 0; img && k < frames.length && !loaded.has(next); k += 1) next = (next + 1) % frames.length;
      layerFor((next + 1) % frames.length); // preload the frame after
      show(next);
    }, PLAY_MS);
  };
  playBtn.addEventListener('click', () => (timer ? stop() : play()));
  slider.addEventListener('input', () => { stop(); show(Number(slider.value)); });

  show(current);
  return () => {
    stop();
    map.remove();
  };
}
