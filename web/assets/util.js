// Shared helpers: API access, German formatting, DOM building (no innerHTML).

const TZ = 'Europe/Berlin';

// --- API -------------------------------------------------------------------

export class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export async function api(path, { method = 'GET', body } = {}) {
  const headers = { Accept: 'application/json' };
  if (method !== 'GET') headers['X-Witterung-Client'] = 'web';
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(path, {
    method,
    headers,
    credentials: 'same-origin',
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 401) {
    location.assign('/auth/login?return_to=' + encodeURIComponent(location.pathname + location.hash));
    throw new ApiError(401, 'Nicht angemeldet – Weiterleitung zur Anmeldung …');
  }
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`.trim();
    try {
      const err = await res.json();
      if (err?.error?.message) message = err.error.message;
    } catch { /* body is not JSON */ }
    throw new ApiError(res.status, message);
  }
  if (res.status === 204) return null;
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// --- Formatting --------------------------------------------------------------

const dtf = (opts) => new Intl.DateTimeFormat('de-DE', { timeZone: TZ, hourCycle: 'h23', ...opts });
const fmtTime = dtf({ hour: '2-digit', minute: '2-digit' });
const fmtDayTime = dtf({ weekday: 'short', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit' });
const fmtWeekday = dtf({ weekday: 'short' });
const fmtDayShort = dtf({ weekday: 'short', day: 'numeric', month: 'numeric' });
const fmtDateKey = new Intl.DateTimeFormat('en-CA', { timeZone: TZ });
// Date-only strings (JJJJ-MM-TT) are formatted in UTC so the weekday never shifts.
const fmtDateOnlyWeekday = new Intl.DateTimeFormat('de-DE', { timeZone: 'UTC', weekday: 'short' });
const fmtDateOnlyLong = new Intl.DateTimeFormat('de-DE', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long' });

/** Accepts RFC 3339 strings and millisecond numbers (both occur in the API). */
export const toDate = (v) => (v == null || v === '' ? null : new Date(v));

export const time = (v) => (toDate(v) ? fmtTime.format(toDate(v)) : '–');
export const dayTime = (v) => (toDate(v) ? fmtDayTime.format(toDate(v)) : '–');
export const weekday = (v) => fmtWeekday.format(toDate(v));
export const dayShort = (v) => fmtDayShort.format(toDate(v));
export const dateKey = (v) => fmtDateKey.format(toDate(v));
/** Local hour 0–23 of a timestamp in Europe/Berlin. */
export const localHour = (v) => Number(fmtTime.format(toDate(v)).slice(0, 2));

export function dayLabel(date, long = false) {
  const today = dateKey(new Date());
  const tomorrow = dateKey(new Date(Date.now() + 864e5));
  if (date === today) return 'Heute';
  if (date === tomorrow) return 'Morgen';
  const d = new Date(date + 'T12:00:00Z');
  return long ? fmtDateOnlyLong.format(d) : `${fmtDateOnlyWeekday.format(d)} ${d.getUTCDate()}.`;
}

const numFormats = new Map();
export function num(v, digits = 0) {
  if (v == null || Number.isNaN(v)) return '–';
  if (!numFormats.has(digits)) {
    numFormats.set(digits, new Intl.NumberFormat('de-DE', { minimumFractionDigits: digits, maximumFractionDigits: digits }));
  }
  // Avoid "-0".
  const r = Number(v.toFixed(digits));
  return numFormats.get(digits).format(r === 0 ? 0 : r);
}

export const temp = (v, digits = 0) => (v == null ? '–' : num(v, digits) + '°');

const rtf = new Intl.RelativeTimeFormat('de', { numeric: 'auto' });
export function relative(v) {
  const d = toDate(v);
  if (!d) return '–';
  const min = Math.round((d - Date.now()) / 60000);
  if (Math.abs(min) < 1) return 'gerade eben';
  if (Math.abs(min) < 60) return rtf.format(min, 'minute');
  if (Math.abs(min) < 36 * 60) return rtf.format(Math.round(min / 60), 'hour');
  return dayTime(d);
}

const COMPASS = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
export const compass = (deg) => (deg == null ? '' : COMPASS[Math.round(deg / 45) % 8]);

export const CONDITIONS = {
  clear: 'Klar', partly_cloudy: 'Teils bewölkt', cloudy: 'Bewölkt', fog: 'Nebel',
  drizzle: 'Nieselregen', rain: 'Regen', heavy_rain: 'Starkregen', snow: 'Schnee',
  sleet: 'Schneeregen', hail: 'Hagel', thunderstorm: 'Gewitter', wind: 'Windig',
};
export function conditionLabel(cond, isDay) {
  if (cond === 'clear' && isDay !== false) return 'Sonnig';
  return CONDITIONS[cond] ?? cond ?? '–';
}
export function conditionIcon(cond, isDay) {
  if (cond === 'clear') return isDay === false ? 'moon' : 'sun';
  if (cond === 'partly_cloudy') return isDay === false ? 'cloud-moon' : 'cloud-sun';
  return CONDITIONS[cond] ? cond : 'cloudy';
}

export const SOURCE_NAMES = {
  'open_meteo:icon_d2': 'ICON-D2',
  'open_meteo:icon_eu': 'ICON-EU',
  'open_meteo:ecmwf_ifs': 'ECMWF IFS',
  'open_meteo:gfs': 'GFS',
  'bright_sky:mosmix': 'MOSMIX',
  'bright_sky:radar': 'DWD-Radar',
  weatherkit: 'Apple Weather',
  pirate_weather: 'Pirate Weather',
};
export const sourceName = (s) => SOURCE_NAMES[s] ?? s;

export const PROVIDER_NAMES = {
  open_meteo: 'Open-Meteo',
  bright_sky: 'Bright Sky (DWD)',
  weatherkit: 'Apple WeatherKit',
  pirate_weather: 'Pirate Weather',
};
export const providerName = (p) => PROVIDER_NAMES[p] ?? p;

// --- DOM ---------------------------------------------------------------------

function build(el, attrs, children) {
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : String(c));
  }
  return el;
}

/** h('p', {class: 'x', onclick: fn}, 'text', child) */
export const h = (tag, attrs, ...children) => build(document.createElement(tag), attrs, children);

const SVG_NS = 'http://www.w3.org/2000/svg';
export const s = (tag, attrs, ...children) => build(document.createElementNS(SVG_NS, tag), attrs, children);

export function icon(name, cls = '') {
  return s('svg', { class: `icon ${cls}`.trim(), 'aria-hidden': 'true', focusable: 'false' },
    s('use', { href: `#i-${name}` }));
}

export function errorBox(err, retry) {
  return h('div', { class: 'error-box', role: 'alert' },
    h('p', null, err?.message ?? String(err)),
    retry && h('button', { type: 'button', class: 'btn', onclick: retry }, 'Erneut versuchen'));
}

/** Writes a short status message into a live region. */
export function notice(el, text, kind = 'ok') {
  el.textContent = text;
  el.className = `notice notice-${kind}`;
}

// --- Charts: redraw on resize --------------------------------------------------

const charts = new Set();
export const registerChart = (draw) => { charts.add(draw); draw(); };
export const clearCharts = () => charts.clear();
let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => charts.forEach((draw) => draw()), 120);
});

// --- Attribution (license requirement) ----------------------------------------

const ATTRIBUTION_FALLBACK = {
  open_meteo: { text: 'Wetterdaten von Open-Meteo.com (CC BY 4.0)', url: 'https://open-meteo.com/' },
  bright_sky: { text: 'Quelle: Deutscher Wetterdienst (DWD), abgerufen über Bright Sky', url: 'https://www.dwd.de/' },
  weatherkit: { text: 'Apple Weather', url: 'https://developer.apple.com/weatherkit/data-source-attribution/' },
  pirate_weather: { text: 'Pirate Weather', url: 'https://pirateweather.net/' },
};

export function attributionBlock(fc) {
  const providers = new Set((fc?.sources ?? []).map((x) => x.provider ?? x.source.split(':')[0]));
  let list = fc?.attribution?.length
    ? fc.attribution
    : [...providers].filter((p) => ATTRIBUTION_FALLBACK[p]).map((p) => ({ source: p, ...ATTRIBUTION_FALLBACK[p] }));
  // Apple requires the mark only where WeatherKit data is shown.
  list = list.filter((a) => a.source !== 'weatherkit' || providers.has('weatherkit'));
  return h('footer', { class: 'attribution' },
    h('h2', { class: 'visually-hidden' }, 'Datenquellen'),
    h('ul', null, list.map((a) => h('li', null, attributionItem(a)))));
}

function attributionItem(a) {
  if (a.source === 'weatherkit') {
    return [
      h('span', { class: 'apple-weather-mark' }, 'Apple Weather'),
      ' · ',
      h('a', { href: a.url, rel: 'noopener', target: '_blank' }, 'Rechtliche Hinweise zu den Datenquellen'),
    ];
  }
  if (a.source === 'open_meteo') {
    return [
      h('a', { href: a.url, rel: 'noopener', target: '_blank' }, 'Wetterdaten von Open-Meteo.com'),
      ' (',
      h('a', { href: 'https://creativecommons.org/licenses/by/4.0/deed.de', rel: 'license noopener', target: '_blank' }, 'CC BY 4.0'),
      ')',
    ];
  }
  return h('a', { href: a.url, rel: 'noopener', target: '_blank' }, a.text);
}
