import Foundation

/// The page served by `PluginWebServer` ("Set Up from a Computer"). One
/// self-contained HTML file with no external resources; it talks to
/// `PluginWebAPI` through relative `api/…` URLs under the token path.
enum PluginWebPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Nuvio Plugins</title>
<style>
:root {
  --bg: #f4f4f6; --card: #ffffff; --text: #16161a; --muted: #6b6b76; --line: #e3e3e8;
  --accent: #2f6fed; --accent-text: #ffffff; --danger: #c93a3a; --ok: #1f8a4c; --field: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #111114; --card: #1b1b20; --text: #ececf1; --muted: #9a9aa6; --line: #2d2d35;
    --accent: #5b8cff; --accent-text: #0b0b0d; --danger: #ff7a7a; --ok: #5fd08d; --field: #141418; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 860px; margin: 0 auto; padding: 24px 16px 64px; }
header h1 { margin: 0; font-size: 24px; }
header p { margin: 4px 0 20px; color: var(--muted); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; margin-bottom: 16px; }
.row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.grow { flex: 1 1 240px; min-width: 0; }
h2 { font-size: 18px; margin: 0; }
h3 { font-size: 16px; margin: 0; }
.muted { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
.error { color: var(--danger); }
.okText { color: var(--ok); }
input[type=text], input[type=password], select {
  width: 100%; padding: 9px 11px; border: 1px solid var(--line); border-radius: 9px; background: var(--field); color: var(--text); font: inherit;
}
button { padding: 8px 13px; border-radius: 9px; border: 1px solid var(--line); background: var(--card); color: var(--text); font: inherit; cursor: pointer; }
button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
button.danger { color: var(--danger); }
button:disabled { opacity: .5; cursor: default; }
.switch { display: inline-flex; gap: 8px; align-items: center; cursor: pointer; user-select: none; }
.scraper { border-top: 1px solid var(--line); padding-top: 12px; margin-top: 12px; }
.panel { margin-top: 12px; padding: 12px; border-radius: 10px; background: var(--bg); }
.field { margin-bottom: 12px; }
.field label { display: block; font-weight: 600; margin-bottom: 4px; }
.log { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 360px; overflow: auto; }
.log .error { color: var(--danger); } .log .warn { color: #c98a1a; } .log .net { color: #3f7fc4; }
a.button { display: inline-block; padding: 8px 13px; border-radius: 9px; border: 1px solid var(--line); background: var(--card); color: var(--text); text-decoration: none; }
.switches { display: flex; flex-direction: column; gap: 6px; }
.devrow { margin-top: 8px; }
.stream { padding: 8px 0; border-bottom: 1px solid var(--line); }
.stream:last-child { border-bottom: 0; }
.stream b { white-space: pre-wrap; }
.stream div { white-space: pre-wrap; color: var(--muted); font-size: 13px; }
.badge { display: inline-block; font-size: 11px; padding: 1px 6px; border-radius: 6px; border: 1px solid var(--line); color: var(--muted); margin-left: 6px; }
.hidden { display: none; }
input.small { width: 72px; }
select.auto { width: auto; }
h3.section { margin: 14px 0 4px; font-size: 14px; color: var(--muted); }
</style>
</head>
<body>
<main>
  <header>
    <h1>Nuvio Plugins</h1>
    <p id="status">Connected to your Apple TV. Changes apply there right away.</p>
  </header>

  <section class="card">
    <h2>Add a repository</h2>
    <p class="muted">The link to a plugin manifest.json (a GitHub link works too) or a short code. The repository list syncs with your Nuvio account.</p>
    <div class="row">
      <input class="grow" id="repoUrl" type="text" placeholder="https://…/manifest.json" autocomplete="off" spellcheck="false">
      <button class="primary" id="addRepo">Add</button>
    </div>
    <p class="muted" id="addStatus"></p>
    <div class="switches">
      <label class="switch"><input type="checkbox" id="pluginsEnabled"> Use plugins (streams and subtitles next to your add-ons)</label>
      <label class="switch"><input type="checkbox" id="autoUpdate"> Update repositories automatically (at most once a day, when Nuvio starts)</label>
    </div>
  </section>

  <div id="repos"></div>
  <p class="muted" id="empty"></p>
</main>

<script>
(function () {
  'use strict';
  var state = null;
  var open = {};
  var logTimers = {};

  function api(path, body) {
    var options = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Nuvio': '1' }, body: JSON.stringify(body) };
    return fetch('api/' + path, options).then(function (res) {
      return res.json().catch(function () { return { ok: false, error: 'HTTP ' + res.status }; });
    }, function () {
      document.getElementById('status').textContent = 'The Apple TV is not answering. Open Settings → Plugins → Set Up from a Computer on it again.';
      document.getElementById('status').className = 'error';
      return { ok: false, error: 'Not connected' };
    });
  }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (key) {
      if (key === 'text') node.textContent = attrs[key];
      else if (key === 'class') node.className = attrs[key];
      else if (key.indexOf('on') === 0) node.addEventListener(key.slice(2), attrs[key]);
      else node.setAttribute(key, attrs[key]);
    });
    (children || []).forEach(function (child) { if (child) node.appendChild(child); });
    return node;
  }

  function button(label, onClick, cls) { return el('button', { text: label, onclick: onClick, class: cls || '' }); }

  function load() {
    return api('state').then(function (result) { if (result.ok) { state = result; render(); } });
  }

  function apply(result, statusNode) {
    if (result && result.ok && result.repositories) { state = result; render(); }
    else if (statusNode) { statusNode.textContent = (result && result.error) || 'Failed'; statusNode.className = 'muted error'; }
  }

  function render() {
    document.getElementById('pluginsEnabled').checked = !!state.pluginsEnabled;
    document.getElementById('autoUpdate').checked = state.autoUpdate !== false;
    var container = document.getElementById('repos');
    container.textContent = '';
    var empty = document.getElementById('empty');
    empty.textContent = state.repositories.length ? '' : 'No repositories yet.';
    state.repositories.forEach(function (repo, index) { container.appendChild(renderRepo(repo, index)); });
  }

  function renderRepo(repo, index) {
    var status = el('p', { class: 'muted' });
    var meta = [repo.version ? 'v' + repo.version : '', repo.author, repo.scrapers.length + ' provider' + (repo.scrapers.length === 1 ? '' : 's')].filter(Boolean).join(' · ');
    var card = el('section', { class: 'card' }, [
      el('div', { class: 'row' }, [
        el('div', { class: 'grow' }, [el('h2', { text: repo.name }), el('div', { class: 'muted', text: meta })]),
        button(repo.updating ? 'Updating…' : 'Update', function (e) {
          e.target.disabled = true; e.target.textContent = 'Updating…';
          api('repositories/update', { url: repo.url }).then(function (r) { apply(r, status); });
        }),
        button('↑', function () { api('repositories/move', { url: repo.url, up: true }).then(function (r) { apply(r, status); }); }),
        button('↓', function () { api('repositories/move', { url: repo.url, up: false }).then(function (r) { apply(r, status); }); }),
        button('Remove', function () {
          if (!confirm('Remove ' + repo.name + ' and its providers?')) return;
          api('repositories/remove', { url: repo.url }).then(function (r) { apply(r, status); });
        }, 'danger')
      ]),
      el('div', { class: 'muted', text: repo.url }),
      repo.description ? el('p', { class: 'muted', text: repo.description }) : null,
      repo.error ? el('p', { class: 'muted error', text: '⚠︎ ' + repo.error }) : null,
      el('label', { class: 'switch muted' }, [
        el('input', { type: 'checkbox', onchange: function (e) {
          api('repositories/developer', { url: repo.url, enabled: e.target.checked }).then(function (r) { apply(r, status); });
        } }),
        document.createTextNode('Developer mode: download the code again before every search, or upload it from this computer')
      ]),
      status
    ]);
    card.querySelector('input[type=checkbox]').checked = !!repo.developer;
    repo.scrapers.forEach(function (scraper) { card.appendChild(renderScraper(scraper, repo)); });
    return card;
  }

  function uploadCode(scraper, status) {
    var picker = el('input', { type: 'file', accept: '.js,.mjs,.cjs,text/javascript' });
    picker.onchange = function () {
      var file = picker.files && picker.files[0];
      if (!file) return;
      if (file.size > 7 * 1024 * 1024) { status.textContent = '✕ The file is larger than 7 MB.'; status.className = 'muted error'; return; }
      var reader = new FileReader();
      reader.onload = function () {
        status.textContent = 'Uploading ' + file.name + '…'; status.className = 'muted';
        api('scrapers/code', { id: scraper.id, code: String(reader.result || '') }).then(function (r) {
          if (r.ok) { open[scraper.id] = null; apply(r); }
          else { status.textContent = '✕ ' + (r.error || 'Failed'); status.className = 'muted error'; }
        });
      };
      reader.readAsText(file);
    };
    picker.click();
  }

  function renderScraper(scraper, repo) {
    var panel = el('div', { class: 'panel hidden' });
    var status = el('p', { class: 'muted' });
    var types = (scraper.types || []).map(function (t) { return t === 'tv' ? 'Series' : t.charAt(0).toUpperCase() + t.slice(1); }).join(', ');
    var resources = scraper.resources || ['stream'];
    var names = { stream: 'Streams', subtitles: 'Subtitles', catalog: 'Catalogs', meta: 'Metadata', ratings: 'Ratings' };
    var offers = resources.length === 1 && resources[0] === 'stream' ? '' : resources.map(function (r) { return names[r] || r; }).join(' + ');
    var info = [offers, types, (scraper.languages || []).join(', ').toUpperCase(), scraper.description].filter(Boolean).join(' · ');
    var toggle = el('input', { type: 'checkbox', onchange: function (e) {
      api('scrapers/enabled', { id: scraper.id, enabled: e.target.checked }).then(function (r) { apply(r); });
    } });
    toggle.checked = !!scraper.enabled;
    if (!scraper.manifestEnabled) toggle.disabled = true;
    var node = el('div', { class: 'scraper' }, [
      el('div', { class: 'row' }, [
        el('label', { class: 'switch grow' }, [toggle, el('span', {}, [
          el('b', { text: scraper.name }), el('span', { class: 'badge', text: 'v' + scraper.version }),
          scraper.manifestEnabled ? null : el('span', { class: 'badge', text: 'disabled by its repository' }),
          scraper.uploadedCode ? el('span', { class: 'badge', text: 'uploaded code' }) : null
        ])]),
        scraper.configPage ? el('a', { class: 'button', href: scraper.configPage, target: '_blank', rel: 'noopener', text: 'Configure' }) : null,
        button('Settings', function () { show('settings', scraper, panel); }),
        button('Test', function () { show('test', scraper, panel); }),
        button('Logs', function () { show('logs', scraper, panel); })
      ]),
      info ? el('div', { class: 'muted', text: info }) : null,
      repo && repo.developer ? el('div', { class: 'row devrow' }, [
        button('Upload code…', function () { uploadCode(scraper, status); }),
        scraper.uploadedCode ? button('Use the repository’s code', function () {
          api('scrapers/code/revert', { id: scraper.id }).then(function (r) { apply(r, status); });
        }) : null
      ]) : null,
      status,
      panel
    ]);
    if (open[scraper.id]) show(open[scraper.id], scraper, panel, true);
    return node;
  }

  function show(kind, scraper, panel, keep) {
    stopLogs(scraper.id);
    if (!keep && open[scraper.id] === kind) { open[scraper.id] = null; panel.className = 'panel hidden'; return; }
    open[scraper.id] = kind;
    panel.className = 'panel';
    panel.textContent = '';
    if (kind === 'settings') renderSettings(scraper, panel);
    if (kind === 'test') renderTest(scraper, panel);
    if (kind === 'logs') renderLogs(scraper, panel);
  }

  function renderSettings(scraper, panel) {
    panel.appendChild(el('p', { class: 'muted', text: 'Loading the provider’s settings…' }));
    api('scrapers/settings?id=' + encodeURIComponent(scraper.id)).then(function (result) {
      panel.textContent = '';
      if (!result.ok) { panel.appendChild(el('p', { class: 'error', text: result.error || 'Failed' })); return; }
      if (!result.fields.length) { panel.appendChild(el('p', { class: 'muted', text: 'This provider has no settings.' })); return; }
      var inputs = {};
      result.fields.forEach(function (field) {
        if (field.type === 'info') {
          panel.appendChild(el('div', { class: 'field' }, [
            field.label ? el('b', { text: field.label }) : null,
            field.description ? el('div', { class: 'muted', text: field.description }) : null
          ]));
          return;
        }
        var input;
        var value = result.values[field.key];
        if (field.type === 'select') {
          input = el('select', {}, field.options.map(function (o) { return el('option', { value: o.value, text: o.label }); }));
          input.value = value;
        } else if (field.type === 'toggle') {
          input = el('input', { type: 'checkbox' });
          input.checked = !!value;
        } else {
          input = el('input', { type: field.type === 'password' ? 'password' : 'text', autocomplete: 'off', spellcheck: 'false' });
          input.value = value || '';
          var saved = result.saved && result.saved[field.key];
          input.placeholder = field.type === 'password' && saved ? 'Saved ' + saved + ' · leave empty to keep' : (field.placeholder || '');
        }
        inputs[field.key] = { field: field, input: input };
        var label = field.type === 'toggle'
          ? el('label', { class: 'switch' }, [input, document.createTextNode(field.label)])
          : el('label', { text: field.label });
        panel.appendChild(el('div', { class: 'field' }, [
          label,
          field.type === 'toggle' ? null : input,
          field.description ? el('div', { class: 'muted', text: field.description }) : null
        ]));
      });
      var status = el('p', { class: 'muted' });
      function values() {
        var out = {};
        Object.keys(inputs).forEach(function (key) {
          var item = inputs[key];
          out[key] = item.field.type === 'toggle' ? item.input.checked : item.input.value;
        });
        return out;
      }
      var actions = el('div', { class: 'row' }, [
        button('Save', function () {
          status.textContent = 'Saving…'; status.className = 'muted';
          api('scrapers/settings', { id: scraper.id, values: values() }).then(function (r) {
            if (r.ok) {
              status.textContent = '✓ Saved on the Apple TV'; status.className = 'muted okText';
              Object.keys(inputs).forEach(function (key) {
                var item = inputs[key];
                if (item.field.type !== 'password') return;
                item.input.value = '';
                var hint = r.saved && r.saved[key];
                item.input.placeholder = hint ? 'Saved ' + hint + ' · leave empty to keep' : (item.field.placeholder || '');
              });
            }
            else { status.textContent = '✕ ' + (r.error || 'Failed'); status.className = 'muted error'; }
          });
        }, 'primary'),
        result.canVerify ? button('Verify', function () {
          status.textContent = 'Checking…'; status.className = 'muted';
          api('scrapers/verify', { id: scraper.id, values: values() }).then(function (r) {
            status.textContent = (r.ok ? '✓ ' : '✕ ') + (r.message || r.error || '');
            status.className = 'muted ' + (r.ok ? 'okText' : 'error');
          });
        }) : null
      ]);
      panel.appendChild(actions);
      panel.appendChild(status);
    });
  }

  function renderTest(scraper, panel) {
    var type = el('select', { class: 'auto' }, [el('option', { value: 'movie', text: 'Movie' }), el('option', { value: 'series', text: 'Episode' })]);
    var imdb = el('input', { type: 'text', value: 'tt0133093', spellcheck: 'false' });
    var season = el('input', { type: 'text', value: '1', class: 'small', inputmode: 'numeric' });
    var episode = el('input', { type: 'text', value: '1', class: 'small', inputmode: 'numeric' });
    var episodeFields = el('div', { class: 'row hidden' }, [
      el('label', { text: 'Season' }), season, el('label', { text: 'Episode' }), episode
    ]);
    type.onchange = function () {
      var isMovie = type.value === 'movie';
      imdb.value = isMovie ? 'tt0133093' : 'tt0903747';
      episodeFields.className = isMovie ? 'row hidden' : 'row';
    };
    var output = el('div');
    var run = button('Run', function () {
      run.disabled = true; output.textContent = ''; output.appendChild(el('p', { class: 'muted', text: 'Searching…' }));
      api('scrapers/test', { id: scraper.id, type: type.value, imdbId: imdb.value, season: parseInt(season.value, 10) || 1, episode: parseInt(episode.value, 10) || 1 }).then(function (r) {
        run.disabled = false; output.textContent = '';
        output.appendChild(el('p', { class: r.ok ? 'okText' : 'error', text: (r.sample ? r.sample + ': ' : '') + (r.summary || r.error || 'Failed') }));
        (r.streams || []).forEach(function (s) {
          output.appendChild(el('div', { class: 'stream' }, [
            el('b', { text: s.name }), el('span', { class: 'badge', text: s.kind }), el('div', { text: s.description })
          ]));
        });
        if (r.subtitles && r.subtitles.length) {
          output.appendChild(el('h3', { text: 'Subtitles', class: 'section' }));
          r.subtitles.forEach(function (sub) {
            var host = '';
            try { host = new URL(sub.url).host; } catch (e) { host = sub.url; }
            output.appendChild(el('div', { class: 'stream' }, [
              el('b', { text: sub.label || sub.language }), el('span', { class: 'badge', text: sub.language }), el('div', { text: host })
            ]));
          });
        }
        (r.sections || []).forEach(function (section) {
          output.appendChild(el('h3', { text: section.title, class: 'section' }));
          if (section.error) output.appendChild(el('p', { class: 'error', text: '✕ ' + section.error }));
          (section.lines || []).forEach(function (line) {
            output.appendChild(el('div', { class: 'stream' }, [el('div', { text: line })]));
          });
          if (!section.error && !(section.lines || []).length) output.appendChild(el('p', { class: 'muted', text: section.summary }));
        });
        if (r.log && r.log.length) output.appendChild(logView(r.log));
      });
    }, 'primary');
    panel.appendChild(el('div', { class: 'row' }, [type, el('div', { class: 'grow' }, [imdb]), run]));
    panel.appendChild(episodeFields);
    panel.appendChild(output);
  }

  function logView(entries) {
    var box = el('div', { class: 'log' });
    entries.forEach(function (entry) {
      box.appendChild(el('div', { class: entry.level, text: (entry.time ? new Date(entry.time).toLocaleTimeString() + ' ' : '') + entry.message }));
    });
    return box;
  }

  function renderLogs(scraper, panel) {
    var box = el('div');
    var clear = button('Clear', function () { api('scrapers/logs/clear', { id: scraper.id }).then(refresh); });
    panel.appendChild(el('div', { class: 'row' }, [el('span', { class: 'muted grow', text: 'Newest last, requests in blue (keys hidden). Updates every 2 seconds while open.' }), clear]));
    panel.appendChild(box);
    function refresh() {
      api('scrapers/logs?id=' + encodeURIComponent(scraper.id)).then(function (r) {
        box.textContent = '';
        if (!r.entries || !r.entries.length) { box.appendChild(el('p', { class: 'muted', text: 'Nothing logged yet.' })); return; }
        var view = logView(r.entries);
        box.appendChild(view);
        view.scrollTop = view.scrollHeight;
      });
    }
    refresh();
    logTimers[scraper.id] = setInterval(refresh, 2000);
  }

  function stopLogs(id) { if (logTimers[id]) { clearInterval(logTimers[id]); delete logTimers[id]; } }

  document.getElementById('addRepo').onclick = function () {
    var input = document.getElementById('repoUrl');
    var status = document.getElementById('addStatus');
    var url = input.value.trim();
    if (!url) return;
    status.textContent = 'Adding…'; status.className = 'muted';
    api('repositories/add', { url: url }).then(function (r) {
      if (r.ok) { input.value = ''; status.textContent = '✓ Added ' + r.added; status.className = 'muted okText'; apply(r); }
      else { status.textContent = '✕ ' + (r.error || 'Failed'); status.className = 'muted error'; }
    });
  };
  document.getElementById('repoUrl').addEventListener('keydown', function (e) { if (e.key === 'Enter') document.getElementById('addRepo').click(); });
  document.getElementById('pluginsEnabled').onchange = function (e) { api('plugins-enabled', { enabled: e.target.checked }).then(function (r) { apply(r); }); };
  document.getElementById('autoUpdate').onchange = function (e) { api('auto-update', { enabled: e.target.checked }).then(function (r) { apply(r); }); };

  load();
})();
</script>
</body>
</html>
"""#
}
