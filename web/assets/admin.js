// Admin view: places, provider status and quotas, ntfy notifications, devices.

import { api, h, icon, num, relative, dayTime, providerName, notice, errorBox } from '/assets/util.js';
import { getPlaces, invalidate, geolocate } from '/assets/app.js';

export async function renderAdmin(root) {
  const sections = [placesSection, statusSection, notificationsSection, devicesSection].map((build) => {
    const el = h('section', { class: 'card' });
    const run = async () => {
      el.replaceChildren(h('p', { class: 'loading' }, 'Lädt …'));
      try {
        await build(el, run);
      } catch (err) {
        if (err.status !== 401) el.replaceChildren(errorBox(err, run));
      }
    };
    return [el, run];
  });
  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Verwaltung')),
    h('div', { class: 'admin-grid' }, sections.map(([el]) => el)),
    h('section', { class: 'card account' },
      h('h2', null, 'Sitzung'),
      h('button', { type: 'button', class: 'btn', onclick: logout }, 'Abmelden')));
  // Each section loads on its own: one missing endpoint does not hide the others.
  await Promise.all(sections.map(([, run]) => run()));
}

async function logout() {
  await api('/auth/logout', { method: 'POST' });
  location.assign('/');
}

// --- Places ------------------------------------------------------------------------

async function placesSection(el, reload) {
  const list = await getPlaces(true);
  const msg = h('p', { class: 'notice', role: 'status' });
  const changed = async (text) => {
    invalidate();
    await reload();
    notice(el.querySelector('.notice'), text);
  };
  const act = async (fn, okText) => {
    try {
      await fn();
      await changed(okText);
    } catch (err) {
      if (err.status !== 401) notice(msg, err.message, 'error');
    }
  };

  const rows = list.map((p, i) => {
    const name = h('input', {
      type: 'text', name: 'name', value: p.name, required: true, maxlength: '80', 'aria-label': `Name von ${p.name}`,
      onchange: (e) => {
        const value = e.target.value.trim();
        if (!value) { e.target.value = p.name; return; }
        act(() => api(`/api/v1/places/${p.id}`, { method: 'PATCH', body: { name: value } }), `„${value}“ gespeichert.`);
      },
    });
    return h('li', { class: 'place-row' },
      h('div', { class: 'place-main' },
        name,
        h('span', { class: 'muted small' }, `${num(p.lat, 4)}, ${num(p.lon, 4)}`)),
      h('label', { class: 'switch' },
        h('input', {
          type: 'checkbox', name: 'notify', checked: p.notify,
          onchange: (e) => act(() => api(`/api/v1/places/${p.id}`, { method: 'PATCH', body: { notify: e.target.checked } }),
            e.target.checked ? `Push für „${p.name}“ an.` : `Push für „${p.name}“ aus.`),
        }),
        h('span', null, 'Push')),
      h('div', { class: 'place-actions' },
        h('button', {
          type: 'button', class: 'btn btn-icon', disabled: i === 0, 'aria-label': `${p.name} nach oben`,
          onclick: () => act(() => api(`/api/v1/places/${p.id}`, { method: 'PATCH', body: { position: i - 1 } }), 'Reihenfolge gespeichert.'),
        }, icon('up')),
        h('button', {
          type: 'button', class: 'btn btn-icon', disabled: i === list.length - 1, 'aria-label': `${p.name} nach unten`,
          onclick: () => act(() => api(`/api/v1/places/${p.id}`, { method: 'PATCH', body: { position: i + 1 } }), 'Reihenfolge gespeichert.'),
        }, icon('down')),
        h('button', {
          type: 'button', class: 'btn btn-icon btn-danger', 'aria-label': `${p.name} löschen`,
          onclick: () => {
            if (confirm(`„${p.name}“ löschen?`)) act(() => api(`/api/v1/places/${p.id}`, { method: 'DELETE' }), `„${p.name}“ gelöscht.`);
          },
        }, icon('trash'))));
  });

  const field = (label, attrs) => h('label', { class: 'field' }, h('span', null, label), h('input', attrs));
  const form = h('form', { class: 'place-form' },
    h('h3', null, 'Ort hinzufügen'),
    field('Name', { name: 'name', type: 'text', required: true, maxlength: '80', autocomplete: 'off' }),
    h('div', { class: 'field-row' },
      field('Breite', { name: 'lat', type: 'number', step: 'any', min: '-90', max: '90', required: true, inputmode: 'decimal' }),
      field('Länge', { name: 'lon', type: 'number', step: 'any', min: '-180', max: '180', required: true, inputmode: 'decimal' })),
    h('div', { class: 'form-actions' },
      h('button', {
        type: 'button', class: 'btn',
        onclick: async () => {
          notice(msg, 'Standort wird bestimmt …', 'info');
          try {
            const pos = await geolocate();
            form.elements.lat.value = pos.lat.toFixed(4);
            form.elements.lon.value = pos.lon.toFixed(4);
            notice(msg, 'Standort übernommen.');
          } catch (err) {
            notice(msg, err.message, 'error');
          }
        },
      }, icon('pin'), 'Aktuellen Standort übernehmen'),
      h('button', { type: 'submit', class: 'btn btn-primary' }, 'Hinzufügen')));
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const name = form.elements.name.value.trim();
    const lat = Number(form.elements.lat.value), lon = Number(form.elements.lon.value);
    act(() => api('/api/v1/places', { method: 'POST', body: { name, lat, lon } }), `„${name}“ hinzugefügt.`);
  });

  el.replaceChildren(
    h('h2', null, 'Orte'),
    list.length ? h('ol', { class: 'place-list' }, rows) : h('p', { class: 'muted' }, 'Noch keine Orte gespeichert.'),
    msg,
    form);
}

// --- Status ------------------------------------------------------------------------

const PERIOD = { day: 'heute', month: 'diesen Monat' };

async function statusSection(el) {
  const st = await api('/api/v1/status');
  const providers = Array.isArray(st) ? st : st?.providers ?? [];
  // Feeds sharing one upstream account (quota_account) show the quota once, at the first feed.
  const shownAccounts = new Set();
  el.replaceChildren(
    h('h2', null, 'Quellen und Kontingente'),
    h('ul', { class: 'provider-list' }, providers.map((p) => {
      const [cls, label] = !p.configured ? ['off', 'Nicht eingerichtet'] : p.ok === false || p.error ? ['bad', 'Fehler'] : ['good', 'OK'];
      const account = p.quota_account ?? p.provider;
      const q = !p.configured || shownAccounts.has(account) ? null : p.quota;
      if (q) shownAccounts.add(account);
      const share = q?.limit ? Math.min(1, q.used / q.limit) : 0;
      const fill = h('span', { class: `meter-fill ${share >= 0.9 ? 'is-high' : share >= 0.7 ? 'is-mid' : ''}` });
      fill.style.width = `${share * 100}%`;
      return h('li', { class: 'provider' },
        h('div', { class: 'provider-head' },
          h('strong', null, providerName(p.provider)),
          h('span', { class: `badge badge-${cls}` }, label)),
        p.configured && h('p', { class: 'muted small' },
          p.last_success_at ? `Zuletzt erfolgreich ${relative(p.last_success_at)} (${dayTime(p.last_success_at)})` : 'Noch kein erfolgreicher Abruf',
          p.interval_s ? ` · Takt ${interval(p.interval_s)}` : ''),
        p.error && h('p', { class: 'source-error small' }, p.error),
        q && [
          h('div', {
            class: 'meter', role: 'progressbar', 'aria-label': `Kontingent ${providerName(account)}`,
            'aria-valuemin': '0', 'aria-valuemax': String(q.limit), 'aria-valuenow': String(q.used),
          }, fill),
          h('p', { class: 'muted small' },
            `${num(q.used, q.used % 1 ? 1 : 0)} von ${num(q.limit)} ${PERIOD[q.period] ?? q.period} (UTC) · ${num(share * 100)} %`),
        ],
        !q && p.configured && p.quota && h('p', { class: 'muted small' }, `Kontingent zählt bei ${providerName(account)}.`));
    })),
    h('p', { class: 'muted small' }, 'Grenze = 50 % des Kontingents der Quelle; darüber liefert der Server den letzten Stand.'));
}

const interval = (s) => (s % 3600 === 0 ? `${s / 3600} h` : s % 60 === 0 ? `${s / 60} min` : `${s} s`);

// --- Notifications -----------------------------------------------------------------

async function notificationsSection(el, reload) {
  const cfg = await api('/api/v1/settings/notifications');
  const msg = h('p', { class: 'notice', role: 'status' });
  const field = (label, attrs, hint) => h('label', { class: 'field' },
    h('span', null, label), h('input', attrs), hint && h('small', { class: 'muted' }, hint));
  const form = h('form', { class: 'ntfy-form' },
    h('label', { class: 'switch' },
      h('input', { type: 'checkbox', name: 'enabled', checked: cfg.enabled }),
      h('span', null, 'Benachrichtigungen aktiv')),
    field('ntfy-Server', { name: 'ntfy_url', type: 'url', required: true, value: cfg.ntfy_url ?? '', placeholder: 'https://ntfy.example.org' }),
    field('Topic', { name: 'topic', type: 'text', required: true, value: cfg.topic ?? '', autocomplete: 'off', spellcheck: 'false' }),
    field('Zugangs-Token', {
      name: 'token', type: 'password', autocomplete: 'new-password',
      placeholder: cfg.token_set ? 'gesetzt – leer lassen zum Behalten' : 'optional',
    }, cfg.token_set ? 'Ein Token ist hinterlegt und wird nie angezeigt.' : null),
    h('div', { class: 'form-actions' },
      h('button', { type: 'submit', class: 'btn btn-primary' }, 'Speichern'),
      h('button', {
        type: 'button', class: 'btn',
        onclick: async () => {
          try {
            await api('/api/v1/settings/notifications/test', { method: 'POST' });
            notice(msg, 'Testnachricht verschickt.');
          } catch (err) {
            if (err.status !== 401) notice(msg, err.message, 'error');
          }
        },
      }, 'Testnachricht senden')));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = form.elements;
    const body = { ntfy_url: f.ntfy_url.value.trim(), topic: f.topic.value.trim(), enabled: f.enabled.checked };
    if (f.token.value) body.token = f.token.value; // omitted = keep the stored token
    try {
      await api('/api/v1/settings/notifications', { method: 'PUT', body });
      await reload();
      notice(el.querySelector('.notice'), 'Gespeichert.');
    } catch (err) {
      if (err.status !== 401) notice(msg, err.message, 'error');
    }
  });
  el.replaceChildren(
    h('h2', null, 'Benachrichtigungen'),
    h('p', { class: 'muted small' }, 'Push über ntfy bei neuer DWD-Warnung (ab „markant“) und bei Regenbeginn in unter 30 Minuten, für Orte mit „Push“.'),
    form,
    msg);
}

// --- Devices -----------------------------------------------------------------------

async function devicesSection(el, reload) {
  const devices = await api('/api/v1/devices');
  const msg = h('p', { class: 'notice', role: 'status' });
  // Token for a client without a browser (e.g. the Mac menu bar). The server
  // stores only its hash, so it is shown exactly once, right here.
  const form = h('form', { class: 'device-form' },
    h('h3', null, 'Token für ein Gerät ohne Browser'),
    h('label', { class: 'field' },
      h('span', null, 'Name'),
      h('input', { name: 'name', type: 'text', required: true, maxlength: '60', autocomplete: 'off', placeholder: 'z. B. Mac-Leiste' })),
    h('div', { class: 'form-actions' },
      h('button', { type: 'submit', class: 'btn btn-primary' }, 'Token erzeugen')));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = form.elements.name.value.trim();
    try {
      const { token } = await api('/api/v1/devices', { method: 'POST', body: { name } });
      await reload();
      const out = h('input', { type: 'text', readonly: true, value: token, 'aria-label': `Token für ${name}`, onfocus: (ev) => ev.target.select() });
      const shown = h('p', { class: 'notice', role: 'status' });
      el.append(h('div', { class: 'device-form token-box' },
        h('h3', null, `Token für „${name}“`),
        out,
        h('div', { class: 'form-actions' },
          h('button', {
            type: 'button', class: 'btn',
            onclick: async () => {
              try {
                await navigator.clipboard.writeText(token);
                notice(shown, 'Kopiert.');
              } catch {
                out.select();
                notice(shown, 'Kopieren nicht erlaubt – Token ist markiert.', 'info');
              }
            },
          }, 'Kopieren')),
        h('p', { class: 'muted small' }, 'Wird nur jetzt angezeigt. Verloren? Gerät widerrufen und neu erzeugen.'),
        shown));
    } catch (err) {
      if (err.status !== 401) notice(msg, err.message, 'error');
    }
  });
  el.replaceChildren(
    h('h2', null, 'Geräte'),
    devices.length
      ? h('ul', { class: 'device-list' }, devices.map((d) => h('li', null,
        h('div', null,
          h('strong', null, d.name || `Gerät ${d.id}`),
          h('p', { class: 'muted small' },
            `Angemeldet ${dayTime(d.created_at)}`,
            d.last_used_at && ` · zuletzt aktiv ${relative(d.last_used_at)}`)),
        h('button', {
          type: 'button', class: 'btn btn-danger',
          onclick: async () => {
            if (!confirm(`„${d.name}“ abmelden? Die App auf diesem Gerät muss sich danach neu anmelden.`)) return;
            try {
              await api(`/api/v1/devices/${d.id}`, { method: 'DELETE' });
              await reload();
              notice(el.querySelector('.notice'), `„${d.name}“ widerrufen.`);
            } catch (err) {
              if (err.status !== 401) notice(msg, err.message, 'error');
            }
          },
        }, 'Widerrufen'))))
      : h('p', { class: 'muted' }, 'Keine Geräte angemeldet.'),
    msg,
    form);
}
