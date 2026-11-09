// Weather view: now, DWD warnings, nowcast, 48 h chart, 10 days.

import {
  h, s, icon, num, temp, time, dayTime, dateKey, dayShort, localHour, dayLabel, relative, compass,
  conditionLabel, conditionIcon, sourceName, attributionBlock, registerChart, errorBox,
} from '/assets/util.js';
import { resolvePlace, loadForecast, placeBar, HERE } from '/assets/app.js';

export async function renderWeather(root, param) {
  const { key, places } = await resolvePlace(param);
  const body = h('div', { class: 'stack' });
  const load = async (force) => {
    body.replaceChildren(h('p', { class: 'loading' }, key === HERE ? 'Standort wird bestimmt …' : 'Lädt …'));
    try {
      const fc = await loadForecast(key, force);
      if (!body.isConnected) return;
      // replaceChildren would print null as text: drop empty sections.
      body.replaceChildren(...[
        header(fc),
        alerts(fc.alerts ?? []),
        nowCard(fc),
        nowcastCard(fc.nowcast),
        hourlyCard(fc.hourly ?? []),
        dailyCard(fc.daily ?? []),
        attributionBlock(fc),
      ].filter(Boolean));
      for (const draw of body.querySelectorAll('[data-chart]')) registerChart(draw.chartDraw);
    } catch (err) {
      if (err.status !== 401) body.replaceChildren(errorBox(err, () => load(true)));
    }
  };
  root.replaceChildren(placeBar('wetter', key, places, () => load(true)), body);
  await load(false);
}

function header(fc) {
  const failed = (fc.sources ?? []).filter((x) => !x.ok || x.stale);
  return h('div', { class: 'view-head' },
    h('h1', null, fc.location?.name ?? 'Wetter'),
    h('p', { class: 'muted' },
      `Stand ${time(fc.generated_at)} Uhr · ${(fc.sources ?? []).filter((x) => x.ok).length} von ${(fc.sources ?? []).length} Quellen`,
      failed.length > 0 && [' · ', h('a', { href: '#/vergleich' }, `${failed.length} mit Problemen`)]));
}

// --- Warnings --------------------------------------------------------------------

const SEVERITY = {
  minor: 'Wetterwarnung',
  moderate: 'Markante Wetterwarnung',
  severe: 'Unwetterwarnung',
  extreme: 'Extremes Unwetter',
};

function alerts(list) {
  if (!list.length) return null;
  return h('section', { class: 'alerts', 'aria-label': 'Amtliche Warnungen des DWD' },
    list.map((a) => h('details', { class: `alert sev-${a.severity}` },
      h('summary', null,
        icon('warning', 'alert-icon'),
        h('span', { class: 'alert-title' },
          h('strong', null, a.headline || a.event),
          h('span', { class: 'alert-meta' },
            `${SEVERITY[a.severity] ?? a.severity} · ${period(a.onset, a.expires)}`))),
      h('div', { class: 'alert-body' },
        a.description && h('p', null, a.description),
        a.instruction && h('p', { class: 'alert-instruction' }, a.instruction),
        h('p', { class: 'muted small' }, 'Quelle: Deutscher Wetterdienst')))));
}

/** "Mo., 9.11., 14:00 bis 22:00 Uhr", the date only once if both are on the same day. */
function period(from, to) {
  if (!to) return `ab ${dayTime(from)} Uhr`;
  return `${dayTime(from)} bis ${dateKey(from) === dateKey(to) ? time(to) : dayTime(to)} Uhr`;
}

// --- Now ---------------------------------------------------------------------------

function nowCard(fc) {
  const obs = fc.now?.observed ?? null;
  const f = fc.now?.forecast ?? null;
  const spread = fc.hourly?.[0]?.spread;
  const today = fc.daily?.[0]?.consensus;
  const cond = obs?.condition ?? f?.condition;
  const isDay = f?.is_day;
  const t = obs?.temp_c ?? f?.temp_c;
  const wind = obs?.wind_kmh ?? f?.wind_kmh;
  const gust = obs?.gust_kmh ?? f?.gust_kmh;
  const dir = obs?.wind_dir_deg ?? f?.wind_dir_deg;

  const facts = [
    ['Wind', wind == null ? '–' : [
      dir != null && windArrow(dir),
      `${num(wind)} km/h ${compass(dir)}`.trim(),
      gust != null ? `, Böen ${num(gust)}` : '',
    ]],
    ['Gefühlt', temp(f?.feels_like_c)],
    ['Feuchte', pct(obs?.humidity_pct ?? f?.humidity_pct)],
    ['Luftdruck', (obs?.pressure_hpa ?? f?.pressure_hpa) == null ? '–' : `${num(obs?.pressure_hpa ?? f?.pressure_hpa)} hPa`],
    ['Niederschlag 1 h', obs ? `${num(obs.precip_mm_1h, 1)} mm` : `${num(f?.precip_mm, 1)} mm`],
    ['Bewölkung', pct(obs?.cloud_pct ?? f?.cloud_pct)],
  ];
  if (obs?.visibility_m != null) facts.push(['Sicht', `${num(obs.visibility_m / 1000, obs.visibility_m < 10000 ? 1 : 0)} km`]);

  return h('section', { class: 'card now', 'aria-labelledby': 'now-h' },
    h('h2', { id: 'now-h', class: 'visually-hidden' }, 'Jetzt'),
    h('div', { class: 'now-main' },
      cond && icon(conditionIcon(cond, isDay), `now-icon cond-${cond}`),
      h('div', null,
        h('p', { class: 'now-temp' }, temp(t, 1)),
        h('p', { class: 'now-cond' }, conditionLabel(cond, isDay)),
        today && h('p', { class: 'muted' },
          `${dayLabel(fc.daily[0].date)}: ${temp(today.temp_min_c)} bis ${temp(today.temp_max_c)}`))),
    h('dl', { class: 'facts' }, facts.map(([k, v]) => h('div', null, h('dt', null, k), h('dd', null, v)))),
    h('p', { class: 'muted small now-source' },
      obs
        ? `Gemessen an der DWD-Station ${obs.station} (${num(obs.distance_m / 1000, 1)} km entfernt), ${time(obs.at)} Uhr.`
        : 'Keine Messstation in der Nähe – Werte aus der Prognose.',
      f && ` Prognose für jetzt: ${temp(f.temp_c, 1)}`,
      f && spread?.temp_c && ` (Spanne ${temp(spread.temp_c.min, 1)} bis ${temp(spread.temp_c.max, 1)}).`));
}

const pct = (v) => (v == null ? '–' : `${num(v)} %`);

function windArrow(deg) {
  const el = icon('arrow', 'wind-arrow');
  el.style.transform = `rotate(${deg}deg)`; // arrow points where the wind blows to
  return el;
}

// --- Nowcast ----------------------------------------------------------------------

const RAIN_MIN = 0.1; // mm/h

export function nowcastSummary(points, now = Date.now()) {
  const future = points.filter((p) => new Date(p.at) >= now - 5 * 60000);
  if (!future.length) return 'Keine Radardaten für die nächsten Stunden.';
  const rainingNow = future[0].precip_mm_h >= RAIN_MIN;
  const switchAt = future.find((p) => (p.precip_mm_h >= RAIN_MIN) !== rainingNow);
  const max = Math.max(...future.map((p) => p.precip_mm_h));
  const mins = (p) => Math.max(0, Math.round((new Date(p.at) - now) / 60000));
  if (rainingNow) {
    return switchAt
      ? `Es regnet. Ende gegen ${time(switchAt.at)} Uhr (in ${mins(switchAt)} min).`
      : `Es regnet und hört in den nächsten 2 Stunden nicht auf (bis ${num(max, 1)} mm/h).`;
  }
  if (!switchAt) return 'Kein Regen in den nächsten 2 Stunden.';
  return `Regen ab ${time(switchAt.at)} Uhr (in ${mins(switchAt)} min), bis ${num(max, 1)} mm/h.`;
}

function nowcastCard(nc) {
  if (!nc?.points?.length) return null;
  const points = nc.points;
  const summary = nowcastSummary(points);
  const wrap = h('div', { class: 'chart chart-nowcast' });
  wrap.dataset.chart = '';
  wrap.chartDraw = () => {
    if (!wrap.isConnected) return;
    const W = Math.max(280, wrap.clientWidth), H = 120, L = 6, R = 40, T = 8, B = 22;
    const pw = W - L - R, ph = H - T - B, slot = pw / points.length;
    const max = Math.max(2, ...points.map((p) => p.precip_mm_h));
    const y = (v) => T + ph - (v / max) * ph;
    const t0 = new Date(points[0].at).getTime();
    const nowX = L + ((Date.now() - t0) / (5 * 60000)) * slot;
    const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: 'img', 'aria-label': `Radar-Niederschlag der nächsten 2 Stunden. ${summary}` },
      [0, max / 2, max].map((v) => [
        s('line', { class: 'grid', x1: L, x2: L + pw, y1: y(v), y2: y(v) }),
        s('text', { class: 'axis', x: L + pw + 4, y: y(v) + 4 }, `${num(v, v < 10 ? 1 : 0)}`),
      ]),
      s('text', { class: 'axis', x: L + pw + 4, y: H - 6 }, 'mm/h'),
      points.map((p, i) => p.precip_mm_h > 0 && s('rect', {
        class: `bar ${p.precip_mm_h >= 10 ? 'bar-heavy' : p.precip_mm_h >= 2.5 ? 'bar-moderate' : ''}`,
        x: L + i * slot + 1, width: Math.max(1, slot - 2), y: y(p.precip_mm_h), height: T + ph - y(p.precip_mm_h), rx: 1.5,
      })),
      points.map((p, i) => (new Date(p.at).getUTCMinutes() % 30 === 0) && s('text', {
        class: 'axis', x: L + i * slot, y: H - 6, 'text-anchor': i === 0 ? 'start' : 'middle',
      }, time(p.at))),
      nowX >= L && nowX <= L + pw && s('line', { class: 'now-line', x1: nowX, x2: nowX, y1: T, y2: T + ph }));
    wrap.replaceChildren(svg);
  };
  return h('section', { class: 'card', 'aria-labelledby': 'nc-h' },
    h('div', { class: 'card-head' },
      h('h2', { id: 'nc-h' }, 'Nächste 2 Stunden'),
      h('span', { class: 'muted small' }, `${sourceName(nc.source)}, ${relative(nc.at)}`)),
    h('p', { class: 'nowcast-summary' }, icon('drop', 'inline-icon'), summary),
    wrap);
}

// --- 48 hours ---------------------------------------------------------------------

function hourLine(hr) {
  const c = hr.consensus ?? {};
  const sp = hr.spread ?? {};
  const range = (r, d = 0) => (r && r.min !== r.max ? ` (${num(r.min, d)} bis ${num(r.max, d)})` : '');
  return `${dayShort(hr.at)}, ${time(hr.at)} Uhr: ${temp(c.temp_c, 1)}${range(sp.temp_c, 1)}, `
    + `${conditionLabel(c.condition, c.is_day)}, ${num(c.precip_mm, 1)} mm`
    + `${sp.precip_agreement_pct != null ? ` (${num(sp.precip_agreement_pct)} % der Quellen)` : ''}, `
    + `Wind ${num(c.wind_kmh)} km/h${c.gust_kmh != null ? `, Böen ${num(c.gust_kmh)}` : ''} · ${hr.n_sources} Quellen`;
}

function hourlyCard(hours) {
  if (!hours.length) return null;
  const n = hours.length;
  let sel = 0;
  const readout = h('p', { class: 'readout' });
  const wrap = h('div', { class: 'chart chart-hourly' });
  wrap.dataset.chart = '';

  const draw = () => {
    if (!wrap.isConnected) return;
    const W = Math.max(300, wrap.clientWidth), H = 250, L = 30, R = 34, T = 24, B = 22;
    const pw = W - L - R, ph = H - T - B, slot = pw / n;
    const cx = (i) => L + (i + 0.5) * slot;

    const temps = hours.flatMap((x) => [x.consensus?.temp_c, x.spread?.temp_c?.min, x.spread?.temp_c?.max]).filter((v) => v != null);
    let lo = Math.floor(Math.min(...temps)) - 1, hi = Math.ceil(Math.max(...temps)) + 1;
    const step = hi - lo > 14 ? 5 : hi - lo > 7 ? 2 : 1;
    lo = Math.floor(lo / step) * step; hi = Math.ceil(hi / step) * step;
    const ty = (v) => T + ph - ((v - lo) / (hi - lo)) * ph;

    const pmax = Math.max(2, ...hours.map((x) => Math.max(x.consensus?.precip_mm ?? 0, x.spread?.precip_mm?.max ?? 0)));
    const pzone = ph * 0.45;
    const py = (v) => T + ph - (v / pmax) * pzone;

    const ticks = [];
    for (let v = lo; v <= hi; v += step) ticks.push(v);
    const every = W < 560 ? 6 : 3;

    const band = hours.map((x, i) => [cx(i), x.spread?.temp_c]).filter(([, r]) => r);
    const bandPath = band.length
      ? 'M' + band.map(([x, r]) => `${x},${ty(r.max)}`).join('L') + 'L' + band.reverse().map(([x, r]) => `${x},${ty(r.min)}`).join('L') + 'Z'
      : '';
    const line = hours.map((x, i) => [cx(i), x.consensus?.temp_c]).filter(([, v]) => v != null);
    const linePath = 'M' + line.map(([x, v]) => `${x},${ty(v)}`).join('L');

    const t0 = new Date(hours[0].at).getTime();
    const nowX = L + ((Date.now() - t0) / 36e5) * slot;
    const selT = hours[sel].consensus?.temp_c;

    const svg = s('svg', {
      viewBox: `0 0 ${W} ${H}`, width: W, height: H, tabindex: '0', role: 'slider',
      'aria-label': '48-Stunden-Verlauf, Pfeiltasten wählen die Stunde',
      'aria-valuemin': '0', 'aria-valuemax': String(n - 1), 'aria-valuenow': String(sel), 'aria-valuetext': hourLine(hours[sel]),
    },
    ticks.map((v) => [
      s('line', { class: 'grid', x1: L, x2: L + pw, y1: ty(v), y2: ty(v) }),
      s('text', { class: 'axis', x: L - 5, y: ty(v) + 4, 'text-anchor': 'end' }, `${num(v)}°`),
    ]),
    s('line', { class: 'grid grid-rain', x1: L, x2: L + pw, y1: py(pmax), y2: py(pmax) }),
    s('text', { class: 'axis axis-rain', x: L + pw + 4, y: py(pmax) - 2 }, num(pmax, pmax < 10 ? 1 : 0)),
    s('text', { class: 'axis axis-rain', x: L + pw + 4, y: py(pmax) + 10 }, 'mm'),
    hours.map((x, i) => {
      const hour = localHour(x.at);
      const out = [];
      if (hour === 0 && i > 0) out.push(s('line', { class: 'day-line', x1: L + i * slot, x2: L + i * slot, y1: 4, y2: T + ph }));
      if (hour === 0 || i === 0) out.push(s('text', { class: 'axis day-label', x: L + i * slot + 4, y: 14 }, i === 0 ? 'Heute' : dayShort(x.at)));
      if (hour % every === 0) out.push(s('text', { class: 'axis', x: cx(i), y: H - 6, 'text-anchor': 'middle' }, String(hour).padStart(2, '0')));
      const pMax = x.spread?.precip_mm?.max ?? 0, p = x.consensus?.precip_mm ?? 0;
      if (pMax > 0) out.push(s('rect', { class: 'bar bar-spread', x: cx(i) - slot * 0.35, width: slot * 0.7, y: py(pMax), height: py(0) - py(pMax), rx: 1 }));
      if (p > 0) out.push(s('rect', { class: 'bar', x: cx(i) - slot * 0.35, width: slot * 0.7, y: py(p), height: py(0) - py(p), rx: 1 }));
      return out;
    }),
    bandPath && s('path', { class: 'temp-band', d: bandPath }),
    s('path', { class: 'temp-line', d: linePath }),
    nowX >= L && nowX <= L + pw && s('line', { class: 'now-line', x1: nowX, x2: nowX, y1: T, y2: T + ph }),
    s('line', { class: 'sel-line', x1: cx(sel), x2: cx(sel), y1: T, y2: T + ph }),
    selT != null && s('circle', { class: 'sel-dot', cx: cx(sel), cy: ty(selT), r: 4 }));

    const pick = (e) => {
      const rect = svg.getBoundingClientRect();
      const x = ((e.clientX - rect.left) / rect.width) * W;
      select(Math.floor((x - L) / slot));
    };
    svg.addEventListener('pointermove', pick);
    svg.addEventListener('pointerdown', pick);
    svg.addEventListener('keydown', (e) => {
      const moves = { ArrowRight: 1, ArrowLeft: -1, ArrowUp: 1, ArrowDown: -1, PageUp: 6, PageDown: -6, Home: -n, End: n };
      if (!(e.key in moves)) return;
      e.preventDefault();
      select(sel + moves[e.key], true);
    });
    wrap.replaceChildren(svg);
  };

  const select = (i, focus = false) => {
    i = Math.max(0, Math.min(n - 1, i));
    if (i === sel) return;
    sel = i;
    readout.textContent = hourLine(hours[sel]);
    draw();
    if (focus) wrap.querySelector('svg')?.focus();
  };
  readout.textContent = hourLine(hours[0]);
  wrap.chartDraw = draw;

  return h('section', { class: 'card', 'aria-labelledby': 'h48-h' },
    h('div', { class: 'card-head' },
      h('h2', { id: 'h48-h' }, '48 Stunden'),
      h('span', { class: 'legend' },
        h('span', { class: 'key key-temp' }, 'Temperatur'),
        h('span', { class: 'key key-band' }, 'Spanne'),
        h('span', { class: 'key key-rain' }, 'Niederschlag'))),
    readout,
    wrap,
    hourlyTable(hours));
}

function hourlyTable(hours) {
  return h('details', { class: 'table-details' },
    h('summary', null, 'Als Tabelle'),
    h('div', { class: 'table-scroll' },
      h('table', { class: 'data' },
        h('thead', null, h('tr', null, ['Zeit', 'Wetter', 'Temp.', 'Spanne', 'Niederschl.', 'Quellen m. Regen', 'Wind', 'Böen', 'n']
          .map((x) => h('th', { scope: 'col' }, x)))),
        h('tbody', null, hours.map((x) => {
          const c = x.consensus ?? {}, sp = x.spread ?? {};
          return h('tr', null,
            h('th', { scope: 'row' }, `${dayShort(x.at)} ${time(x.at)}`),
            h('td', null, conditionLabel(c.condition, c.is_day)),
            h('td', { class: 'num' }, temp(c.temp_c, 1)),
            h('td', { class: 'num' }, sp.temp_c ? `${num(sp.temp_c.min, 1)} – ${num(sp.temp_c.max, 1)}` : '–'),
            h('td', { class: 'num' }, `${num(c.precip_mm, 1)} mm`),
            h('td', { class: 'num' }, sp.precip_agreement_pct == null ? '–' : `${num(sp.precip_agreement_pct)} %`),
            h('td', { class: 'num' }, `${num(c.wind_kmh)} km/h`),
            h('td', { class: 'num' }, c.gust_kmh == null ? '–' : `${num(c.gust_kmh)} km/h`),
            h('td', { class: 'num' }, x.n_sources));
        })))));
}

// --- 10 days -----------------------------------------------------------------------

function dailyCard(days) {
  if (!days.length) return null;
  const vals = days.flatMap((d) => [
    d.consensus?.temp_min_c, d.consensus?.temp_max_c, d.spread?.temp_min_c?.min, d.spread?.temp_max_c?.max,
  ]).filter((v) => v != null);
  const lo = Math.min(...vals), hi = Math.max(...vals);
  const pos = (v) => ((v - lo) / (hi - lo || 1)) * 100;
  const place = (el, a, b) => {
    el.style.left = `${pos(a)}%`;
    el.style.width = `${Math.max(1.5, pos(b) - pos(a))}%`;
    return el;
  };

  return h('section', { class: 'card', 'aria-labelledby': 'd10-h' },
    h('div', { class: 'card-head' }, h('h2', { id: 'd10-h' }, '10 Tage')),
    h('ul', { class: 'days' }, days.map((d) => {
      const c = d.consensus ?? {}, sp = d.spread ?? {};
      const sMin = sp.temp_min_c?.min ?? c.temp_min_c, sMax = sp.temp_max_c?.max ?? c.temp_max_c;
      const rain = c.precip_mm >= 0.1;
      const desc = `${dayLabel(d.date, true)}: ${conditionLabel(c.condition, true)}, `
        + `${temp(c.temp_min_c)} bis ${temp(c.temp_max_c)}`
        + (sp.temp_min_c && sp.temp_max_c ? ` (Quellen: Tiefst ${num(sp.temp_min_c.min)} bis ${num(sp.temp_min_c.max)}, Höchst ${num(sp.temp_max_c.min)} bis ${num(sp.temp_max_c.max)})` : '')
        + `, ${num(c.precip_mm, 1)} mm Niederschlag`
        + (sp.precip_agreement_pct != null ? ` (${num(sp.precip_agreement_pct)} % der Quellen)` : '')
        + `, ${d.n_sources} Quellen`;
      return h('li', { class: 'day' },
        h('span', { class: 'visually-hidden' }, desc),
        h('span', { class: 'day-name', 'aria-hidden': 'true' }, dayLabel(d.date)),
        h('span', { 'aria-hidden': 'true', title: conditionLabel(c.condition, true) }, icon(conditionIcon(c.condition, true), `day-icon cond-${c.condition}`)),
        h('span', { class: `day-rain ${rain ? '' : 'is-dry'}`, 'aria-hidden': 'true' },
          rain ? [`${num(c.precip_mm, 1)} mm`, sp.precip_agreement_pct != null && h('small', null, ` ${num(sp.precip_agreement_pct)} %`)] : '–'),
        h('span', { class: 'day-min', 'aria-hidden': 'true' }, temp(c.temp_min_c)),
        h('span', { class: 'range', 'aria-hidden': 'true' },
          place(h('span', { class: 'range-spread' }), sMin, sMax),
          place(h('span', { class: 'range-bar' }), c.temp_min_c, c.temp_max_c)),
        h('span', { class: 'day-max', 'aria-hidden': 'true' }, temp(c.temp_max_c)),
        h('span', { class: 'day-n muted', 'aria-hidden': 'true', title: `${d.n_sources} Quellen` }, `${d.n_sources} Q.`));
    })),
    h('p', { class: 'muted small' }, 'Dunkler Balken: Tiefst- bis Höchstwert im Konsens (Median). Heller Bereich: Spanne aller Quellen. Prozent: Anteil der Quellen mit mindestens 1 mm.'));
}
