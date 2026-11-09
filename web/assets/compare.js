// Source comparison: every source against the consensus, per hour and per day.

import { h, num, time, dateKey, dayLabel, relative, localHour, sourceName, providerName, attributionBlock, errorBox } from '/assets/util.js';
import { resolvePlace, loadForecast, placeBar } from '/assets/app.js';

const METRICS = {
  temp: { label: 'Temperatur', unit: '°C', digits: 1, steps: [1, 2, 3.5] },
  precip: { label: 'Niederschlag', unit: 'mm', digits: 1, steps: [0.3, 1, 3] },
  wind: { label: 'Wind', unit: 'km/h', digits: 0, steps: [5, 10, 18] },
};

// Value getters per metric and resolution. Daily temperature compares min and max.
const GET = {
  hour: {
    temp: (p) => p?.temp_c,
    precip: (p) => p?.precip_mm,
    wind: (p) => p?.wind_kmh,
  },
  day: {
    temp: (p) => (p ? [p.temp_min_c, p.temp_max_c] : null),
    precip: (p) => p?.precip_mm,
    wind: (p) => p?.wind_max_kmh,
  },
};
const SPREAD = {
  hour: { temp: (sp) => sp?.temp_c, precip: (sp) => sp?.precip_mm, wind: (sp) => sp?.wind_kmh },
  day: { temp: (sp) => sp?.temp_max_c, precip: (sp) => sp?.precip_mm, wind: () => null },
};

const prefs = { metric: 'temp', res: 'hour' };

export async function renderCompare(root, param) {
  const { key, places } = await resolvePlace(param);
  const body = h('div', { class: 'stack' });
  root.replaceChildren(placeBar('vergleich', key, places), body);

  const load = async (force) => {
    body.replaceChildren(h('p', { class: 'loading' }, 'Lädt …'));
    try {
      const fc = await loadForecast(key, force);
      if (!body.isConnected) return;
      const table = h('div', { class: 'table-scroll compare-scroll' });
      const legend = h('p', { class: 'muted small' });
      const redraw = () => {
        table.replaceChildren(compareTable(fc));
        const m = METRICS[prefs.metric];
        legend.textContent = `Farbe = Abweichung vom Konsens (Median): ab ±${num(m.steps[0], 1)}, ±${num(m.steps[1], 1)} und ±${num(m.steps[2], 1)} ${m.unit}. `
          + 'Rot: wärmer bzw. mehr, Blau: kälter bzw. weniger. „Ø Abw.“ = mittlere absolute Abweichung.';
      };
      body.replaceChildren(
        h('div', { class: 'view-head' }, h('h1', null, `Quellenvergleich · ${fc.location?.name ?? ''}`)),
        sourceStatus(fc.sources ?? []),
        h('section', { class: 'card', 'aria-labelledby': 'cmp-h' },
          h('div', { class: 'card-head' }, h('h2', { id: 'cmp-h' }, 'Werte je Quelle')),
          h('div', { class: 'controls' },
            segmented('Größe', 'metric', Object.entries(METRICS).map(([k, m]) => [k, m.label]), redraw),
            segmented('Auflösung', 'res', [['hour', '48 Stunden'], ['day', '10 Tage']], redraw)),
          legend,
          table),
        attributionBlock(fc));
      redraw();
    } catch (err) {
      if (err.status !== 401) body.replaceChildren(errorBox(err, () => load(true)));
    }
  };
  await load(false);
}

function segmented(label, prop, options, onChange) {
  return h('fieldset', { class: 'segmented' },
    h('legend', { class: 'visually-hidden' }, label),
    options.map(([value, text]) => h('label', null,
      h('input', {
        type: 'radio', name: prop, value, checked: prefs[prop] === value,
        onchange: () => { prefs[prop] = value; onChange(); },
      }),
      h('span', null, text))));
}

function sourceStatus(sources) {
  return h('section', { class: 'card', 'aria-labelledby': 'src-h' },
    h('div', { class: 'card-head' }, h('h2', { id: 'src-h' }, 'Quellen')),
    h('ul', { class: 'source-list' }, sources.map((x) => {
      const [cls, label] = !x.ok ? ['bad', 'Fehler'] : x.stale ? ['warn', 'Veraltet'] : ['good', 'Aktuell'];
      return h('li', null,
        h('span', { class: `badge badge-${cls}` }, label),
        h('span', { class: 'source-name' }, sourceName(x.source), h('small', { class: 'muted' }, ` ${providerName(x.provider)}`)),
        h('span', { class: 'muted small' }, x.fetched_at ? `abgerufen ${relative(x.fetched_at)}` : 'noch nie abgerufen'),
        x.error && h('span', { class: 'source-error small' }, x.error));
    })));
}

function deviationClass(diff, steps) {
  if (diff == null || Number.isNaN(diff)) return '';
  const level = steps.filter((st) => Math.abs(diff) >= st).length;
  return level ? `dev dev-${diff > 0 ? 'p' : 'm'}${level}` : '';
}

function compareTable(fc) {
  const { metric, res } = prefs;
  const m = METRICS[metric];
  const rows = res === 'hour' ? fc.hourly ?? [] : fc.daily ?? [];
  const get = GET[res][metric];
  const spreadOf = SPREAD[res][metric];
  // Failed sources keep their column (all "–") so the gap is visible; sources without
  // series (radar, station) are left out.
  const sources = (fc.sources ?? [])
    .filter((x) => [...(fc.hourly ?? []), ...(fc.daily ?? [])].some((r) => r.by_source?.[x.source])
      || (!x.ok && !/radar|synop|current|alert/.test(x.source)))
    .map((x) => x.source);

  const fmt = (v) => {
    if (v == null) return '–';
    if (Array.isArray(v)) return v.some((x) => x == null) ? '–' : `${num(v[0], 0)} / ${num(v[1], 0)}`;
    return num(v, m.digits);
  };
  // For min/max pairs the larger deviation decides the colour.
  const diff = (v, c) => {
    if (v == null || c == null) return null;
    if (Array.isArray(v)) {
      const d = [v[0] - c[0], v[1] - c[1]];
      return Math.abs(d[0]) > Math.abs(d[1]) ? d[0] : d[1];
    }
    return v - c;
  };

  const sums = Object.fromEntries(sources.map((src) => [src, { total: 0, n: 0 }]));
  const body = rows.flatMap((r, i) => {
    const c = get(r.consensus);
    const sp = spreadOf(r.spread);
    const dayStart = res === 'hour' && (i === 0 || localHour(r.at) === 0);
    return [
      dayStart && h('tr', { class: 'day-row' },
        h('th', { scope: 'rowgroup', colspan: String(sources.length + 4) }, dayLabel(dateKey(r.at), true))),
      h('tr', null,
        h('th', { scope: 'row' }, res === 'hour' ? time(r.at) : dayLabel(r.date)),
        h('td', { class: 'num consensus' }, fmt(c)),
        sources.map((src) => {
          const v = get(r.by_source?.[src]);
          const d = diff(v, c);
          if (d != null) { sums[src].total += Math.abs(d); sums[src].n += 1; }
          return h('td', {
            class: `num ${deviationClass(d, m.steps)}`.trim(),
            title: d == null ? null : `${sourceName(src)}: ${d > 0 ? '+' : ''}${num(d, m.digits)} ${m.unit} zum Konsens`,
          }, fmt(v));
        }),
        h('td', { class: 'num muted' }, !sp ? '–' : sp.min === sp.max ? num(sp.min, m.digits) : `${num(sp.min, m.digits)} – ${num(sp.max, m.digits)}`),
        h('td', { class: 'num muted' }, r.n_sources)),
    ];
  });

  return h('table', { class: 'data compare' },
    h('caption', { class: 'visually-hidden' }, `${m.label} in ${m.unit} je Quelle, ${res === 'hour' ? 'stündlich' : 'täglich'}`),
    h('thead', null, h('tr', null,
      h('th', { scope: 'col' }, res === 'hour' ? 'Zeit' : 'Tag'),
      h('th', { scope: 'col' }, 'Konsens'),
      sources.map((src) => h('th', { scope: 'col' }, sourceName(src))),
      h('th', { scope: 'col' }, 'Spanne'),
      h('th', { scope: 'col' }, h('abbr', { title: 'Anzahl Quellen' }, 'n')))),
    h('tbody', null, body),
    h('tfoot', null, h('tr', null,
      h('th', { scope: 'row' }, 'Ø Abw.'),
      h('td'),
      sources.map((src) => h('td', { class: 'num' }, sums[src].n ? num(sums[src].total / sums[src].n, m.digits) : '–')),
      h('td', { colspan: '2' }))));
}
