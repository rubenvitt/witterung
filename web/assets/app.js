// Shell: hash routing, place selection, cached forecast loading.

import { api, h, icon, errorBox, clearCharts } from '/assets/util.js';
import { renderWeather } from '/assets/weather.js';
import { renderCompare } from '/assets/compare.js';
import { renderRadar } from '/assets/radar.js';
import { renderAdmin } from '/assets/admin.js';

const VIEWS = {
  wetter: { render: renderWeather, title: 'Wetter' },
  vergleich: { render: renderCompare, title: 'Quellenvergleich' },
  radar: { render: renderRadar, title: 'Radar' },
  verwaltung: { render: renderAdmin, title: 'Verwaltung' },
};

export const HERE = 'hier';
const PLACE_KEY = 'witterung.place';
const MAX_AGE_MS = 5 * 60 * 1000;

let places = null;
const forecasts = new Map(); // placeKey -> { at, promise }
let position = null; // { at, lat, lon }

export async function getPlaces(force = false) {
  if (!places || force) places = await api('/api/v1/places');
  return places;
}

/** Forget cached data after writes in the admin view. */
export function invalidate() {
  places = null;
  forecasts.clear();
}

function storedPlace() {
  try { return localStorage.getItem(PLACE_KEY); } catch { return null; }
}

/** The place to show: route parameter, last choice, first saved place, or the current location. */
export async function resolvePlace(param) {
  const list = await getPlaces();
  const valid = (k) => k === HERE || list.some((p) => String(p.id) === k);
  const key = [param, storedPlace()].find((k) => k && valid(k)) ?? (list[0] ? String(list[0].id) : HERE);
  try { localStorage.setItem(PLACE_KEY, key); } catch { /* private mode */ }
  return { key, place: list.find((p) => String(p.id) === key) ?? null, places: list };
}

export function geolocate() {
  if (position && Date.now() - position.at < MAX_AGE_MS) return Promise.resolve(position);
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject(new Error('Dieser Browser kann den Standort nicht bestimmen.'));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (p) => {
        position = { at: Date.now(), lat: p.coords.latitude, lon: p.coords.longitude };
        resolve(position);
      },
      (e) => reject(new Error(e.code === e.PERMISSION_DENIED
        ? 'Standortzugriff verweigert. Erlaube ihn im Browser oder wähle einen gespeicherten Ort.'
        : 'Standort nicht verfügbar.')),
      { enableHighAccuracy: false, timeout: 15000, maximumAge: MAX_AGE_MS },
    );
  });
}

export function loadForecast(key, force = false) {
  const hit = forecasts.get(key);
  if (hit && !force && Date.now() - hit.at < MAX_AGE_MS) return hit.promise;
  const promise = key === HERE
    ? geolocate().then((p) => api(`/api/v1/forecast?lat=${p.lat.toFixed(4)}&lon=${p.lon.toFixed(4)}`))
    : api(`/api/v1/places/${encodeURIComponent(key)}/forecast`);
  forecasts.set(key, { at: Date.now(), promise });
  promise.catch(() => forecasts.delete(key));
  return promise;
}

/** Toolbar with the place selector (and an optional refresh button). */
export function placeBar(view, key, list, onRefresh) {
  const select = h('select', {
    id: 'place-select',
    onchange: (e) => { location.hash = `#/${view}/${e.target.value}`; },
  },
  list.map((p) => h('option', { value: String(p.id), selected: String(p.id) === key }, p.name)),
  h('option', { value: HERE, selected: key === HERE }, 'Mein Standort'));
  return h('div', { class: 'placebar' },
    h('label', { for: 'place-select', class: 'placebar-label' }, icon('pin'), h('span', { class: 'visually-hidden' }, 'Ort')),
    select,
    onRefresh && h('button', { type: 'button', class: 'btn btn-icon', onclick: onRefresh, 'aria-label': 'Aktualisieren', title: 'Aktualisieren' }, icon('refresh')));
}

// --- Router --------------------------------------------------------------------

const main = document.getElementById('main');
let cleanup = null;

async function route() {
  const hash = location.hash;
  if (hash && !hash.startsWith('#/')) return;
  const [name, param] = hash.replace(/^#\/?/, '').split('/');
  const viewName = VIEWS[name] ? name : 'wetter';
  const view = VIEWS[viewName];

  for (const a of document.querySelectorAll('.mainnav a')) {
    if (a.dataset.view === viewName) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  }
  document.title = `${view.title} · Witterung`;

  cleanup?.();
  cleanup = null;
  clearCharts();
  const root = h('div', { class: `view view-${viewName}` });
  main.replaceChildren(root);
  window.scrollTo(0, 0);
  const render = async () => {
    root.replaceChildren(h('p', { class: 'loading' }, 'Lädt …'));
    try {
      const done = await view.render(root, param ? decodeURIComponent(param) : undefined);
      if (root.isConnected) cleanup = done ?? null;
      else done?.();
    } catch (err) {
      if (root.isConnected && err.status !== 401) root.replaceChildren(errorBox(err, render));
    }
  };
  await render();
}

document.querySelector('.skip-link').addEventListener('click', (e) => {
  e.preventDefault();
  main.focus();
});
window.addEventListener('hashchange', route);
route();
