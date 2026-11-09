// Radar map: DWD WMS (RV product) over OpenStreetMap, time slider with play.

import { api, h, icon, time, errorBox } from '/assets/util.js';
import { resolvePlace, placeBar, geolocate, HERE } from '/assets/app.js';

const GERMANY = { lat: 51.2, lon: 10.4, zoom: 6 };
const RADAR_OPACITY = 0.75;
const PLAY_MS = 700;

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
  let current = Math.max(0, frames.findLastIndex((f) => new Date(f) <= now));
  const nowIndex = current;

  const mapEl = h('div', { class: 'map', role: 'region', 'aria-label': 'Radarkarte' });
  const label = h('output', { class: 'frame-label', 'aria-live': 'off' });
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
  map.attributionControl.addAttribution('Radar: <a href="https://www.dwd.de/">Deutscher Wetterdienst</a>');
  if (center !== GERMANY) {
    window.L.circleMarker([center.lat, center.lon], { radius: 6, weight: 2, className: 'place-marker' }).addTo(map);
  }

  // One WMS layer per frame, created on demand: switching opacity does not flicker,
  // swapping TIME on a single layer would.
  // shortcut: layers are never evicted; fine for 49 frames, revisit if frames get many more.
  const layers = new Map();
  const layerFor = (i) => {
    if (!layers.has(i)) {
      layers.set(i, window.L.tileLayer.wms(radar.wms, {
        layers: radar.layer,
        version: '1.3.0',
        format: 'image/png',
        transparent: true,
        TIME: frames[i],
        opacity: 0,
        zIndex: 10,
      }).addTo(map));
    }
    return layers.get(i);
  };

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
      const next = (current + 1) % frames.length;
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
