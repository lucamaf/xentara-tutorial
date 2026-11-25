// The tank station dashboard: shows the data points of the Xentara model (group "Plant") and writes the inputs.
// The data source is either Xentara (XentaraClient: WebSocket interface) or the demo (MockSource: a tank in the browser).
(function () {
  'use strict';

  const NAMES = ['Tank Level', 'Temperature', 'Flow Rate', 'Total Volume', 'Pump Running', 'High Level Alarm', 'Low Level Alarm',
    'Level Setpoint', 'Pump Speed', 'Pump Enable', 'Auto Mode'];
  const WRITE_ONLY = ['Alarm Acknowledge'];
  const NS = 'http://www.w3.org/2000/svg';
  const TREND_SECONDS = 300;

  const $ = (id) => document.getElementById(id);
  const clamp = (v, low, high) => Math.max(low, Math.min(high, v));

  let source = null;
  let snapshot = {};
  let live = false;
  let dirty = true;
  let displayLevel = null;
  const history = [];
  const pending = new Map(); // data point name -> { target, label, since }

  // ------------------------------------------------------------------------------------------------ geometry
  const TANK_TOP = 40;
  const TANK_BOTTOM = 380;
  const yOfLevel = (level) => TANK_BOTTOM - ((TANK_BOTTOM - TANK_TOP) * clamp(level, 0, 100)) / 100;

  function svgEl(tag, attributes, parent) {
    const node = document.createElementNS(NS, tag);
    for (const key of Object.keys(attributes || {})) node.setAttribute(key, attributes[key]);
    if (parent) parent.appendChild(node);
    return node;
  }

  function drawScale() {
    const group = $('ticks');
    for (const level of [0, 25, 50, 75, 100]) {
      const y = yOfLevel(level);
      const tick = svgEl('g', { class: 'tick' }, group);
      svgEl('line', { x1: 140, x2: 150, y1: y, y2: y }, tick);
      const text = svgEl('text', { x: 134, y: y + 4 }, tick);
      text.textContent = level;
    }
  }

  // ------------------------------------------------------------------------------------------------ values
  const value = (name) => (snapshot[name] ? snapshot[name].value : undefined);
  const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);

  function qualityState() {
    const entries = NAMES.map((n) => snapshot[n]).filter(Boolean);
    if (!entries.length) return 'unknown';
    const good = (q) => q === 0 || q === 'good' || q === 'Good' || q === undefined;
    return entries.every((e) => good(e.quality)) ? 'good' : 'bad';
  }

  function render() {
    dirty = false;
    document.body.classList.toggle('stale', !live);

    const level = value('Tank Level');
    const temperature = value('Temperature');
    const flow = value('Flow Rate');
    const total = value('Total Volume');
    const setpoint = value('Level Setpoint');
    const speed = value('Pump Speed');
    const running = Boolean(value('Pump Running'));
    const auto = value('Auto Mode');

    $('v-level').textContent = isNumber(level) ? level.toFixed(1) : '--';
    $('v-temperature').textContent = isNumber(temperature) ? temperature.toFixed(1) : '--';
    $('v-flow').textContent = isNumber(flow) ? Math.round(flow).toLocaleString() : '--';
    $('v-total').textContent = isNumber(total) ? Math.round(total).toLocaleString() : '--';
    $('level-text').textContent = isNumber(level) ? `${level.toFixed(1)} %` : '-- %';

    $('lamp-pump').classList.toggle('on', live && running);
    $('lamp-high').classList.toggle('on', live && Boolean(value('High Level Alarm')));
    $('lamp-low').classList.toggle('on', live && Boolean(value('Low Level Alarm')));
    const quality = qualityState();
    $('lamp-quality').className = 'lamp' + (quality === 'good' ? ' on' : quality === 'bad' ? ' warn' : '');
    $('quality-text').textContent = quality === 'good' ? 'Data quality: good' : quality === 'bad' ? 'Data quality: not good' : 'Data quality';

    // set point marker and the controller's band (set point +/- 5 %, only meaningful in automatic mode)
    if (isNumber(setpoint)) {
      $('setpoint').setAttribute('transform', `translate(0 ${yOfLevel(setpoint)})`);
      $('setpoint-label').textContent = `set point ${Math.round(setpoint)} %`;
      const top = yOfLevel(clamp(setpoint + 5, 0, 100));
      const bottom = yOfLevel(clamp(setpoint - 5, 0, 100));
      $('band').setAttribute('y', top);
      $('band').setAttribute('height', bottom - top);
      $('band').style.display = auto === false ? 'none' : '';
    }

    // pump and pipes
    $('pump-body').classList.toggle('running', live && running);
    $('impeller').classList.toggle('running', live && running);
    $('impeller').style.setProperty('--spin', `${(2.2 - (clamp(Number(speed) || 0, 0, 100) / 100) * 1.8).toFixed(2)}s`);
    $('pump-text').textContent = !live || value('Pump Running') === undefined ? '--' : running ? `${Math.round(speed)} %` : 'off';
    $('inlet-flow').classList.toggle('active', live && running);
    $('outlet-flow').classList.toggle('active', live && isNumber(level) && level > 0);

    syncControls(setpoint, speed, auto, running);
  }

  // the controls show what the model says, unless the user is working with them or a write is on its way
  function syncControls(setpoint, speed, auto, running) {
    const idle = (name, input) => !pending.has(name) && document.activeElement !== input;
    if (isNumber(setpoint)) {
      $('rb-setpoint').textContent = `model: ${Math.round(setpoint)} %`;
      if (idle('Level Setpoint', $('in-setpoint'))) { $('in-setpoint').value = Math.round(setpoint); $('out-setpoint').textContent = Math.round(setpoint); }
    }
    if (isNumber(speed)) {
      $('rb-speed').textContent = `model: ${Math.round(speed)} %`;
      if (idle('Pump Speed', $('in-speed'))) { $('in-speed').value = Math.round(speed); $('out-speed').textContent = Math.round(speed); }
    }
    if (typeof auto === 'boolean' && idle('Auto Mode', $('in-auto'))) $('in-auto').checked = auto;
    const manual = $('in-auto').checked === false;
    $('in-enable').disabled = !manual;
    if (manual) { if (idle('Pump Enable', $('in-enable'))) $('in-enable').checked = Boolean(value('Pump Enable')); }
    else $('in-enable').checked = running;
  }

  // ------------------------------------------------------------------------------------------------ animation
  function frame() {
    const level = value('Tank Level');
    if (isNumber(level)) {
      displayLevel = displayLevel === null ? level : displayLevel + (level - displayLevel) * 0.15;
      const y = yOfLevel(displayLevel);
      $('water').setAttribute('y', y);
      $('water').setAttribute('height', Math.max(0, TANK_BOTTOM - y));
      $('wave-group').setAttribute('transform', `translate(150 ${y - 1})`);
      $('wave-group').style.display = displayLevel < 0.5 ? 'none' : '';
    }
    if (dirty) render();
    requestAnimationFrame(frame);
  }

  // ------------------------------------------------------------------------------------------------ trend
  const PLOT = { left: 50, right: 930, top: 15, bottom: 195 };

  function sample() {
    const level = value('Tank Level');
    if (!live || !isNumber(level)) return;
    const now = Date.now();
    history.push({ t: now, level, setpoint: value('Level Setpoint'), temperature: value('Temperature') });
    while (history.length && history[0].t < now - TREND_SECONDS * 1000 - 5000) history.shift();
    drawTrend();
  }

  function drawTrend() {
    const svg = $('trend');
    svg.textContent = '';
    const w = PLOT.right - PLOT.left;
    const h = PLOT.bottom - PLOT.top;
    const yLevel = (v) => PLOT.bottom - (clamp(v, 0, 100) / 100) * h;
    const yTemp = (v) => PLOT.bottom - ((clamp(v, 10, 40) - 10) / 30) * h;
    const now = Date.now();
    const xOf = (t) => PLOT.left + ((t - (now - TREND_SECONDS * 1000)) / (TREND_SECONDS * 1000)) * w;

    svgEl('rect', { class: 'alarm-zone', x: PLOT.left, y: yLevel(100), width: w, height: yLevel(90) - yLevel(100) }, svg);
    svgEl('rect', { class: 'alarm-zone', x: PLOT.left, y: yLevel(10), width: w, height: yLevel(0) - yLevel(10) }, svg);
    for (const level of [0, 25, 50, 75, 100]) {
      svgEl('line', { class: 'grid', x1: PLOT.left, x2: PLOT.right, y1: yLevel(level), y2: yLevel(level) }, svg);
      svgEl('text', { class: 'axis-label', x: PLOT.left - 6, y: yLevel(level) + 4, 'text-anchor': 'end' }, svg).textContent = `${level} %`;
    }
    for (const temperature of [10, 20, 30, 40]) {
      svgEl('text', { class: 'axis-label', x: PLOT.right + 6, y: yTemp(temperature) + 4 }, svg).textContent = `${temperature} °C`;
    }
    for (let minutes = 0; minutes <= 5; minutes++) {
      const x = PLOT.right - (minutes / 5) * w;
      svgEl('line', { class: 'grid', x1: x, x2: x, y1: PLOT.top, y2: PLOT.bottom }, svg);
      svgEl('text', { class: 'axis-label', x, y: PLOT.bottom + 16, 'text-anchor': 'middle' }, svg).textContent = minutes === 0 ? 'now' : `-${minutes} min`;
    }
    const line = (cls, pick, scale) => {
      const points = history.filter((p) => isNumber(pick(p))).map((p) => `${xOf(p.t).toFixed(1)},${scale(pick(p)).toFixed(1)}`);
      if (points.length > 1) svgEl('polyline', { class: `series ${cls}`, points: points.join(' ') }, svg);
    };
    line('temperature', (p) => p.temperature, yTemp);
    line('setpoint', (p) => p.setpoint, yLevel);
    line('level', (p) => p.level, yLevel);
  }

  // ------------------------------------------------------------------------------------------------ inputs
  function setWriteStatus(text, kind) {
    const el = $('write-status');
    el.textContent = text;
    el.className = 'write-status' + (kind ? ' ' + kind : '');
  }

  const matches = (name, target) => {
    const actual = value(name);
    if (typeof target === 'boolean') return Boolean(actual) === target;
    return isNumber(actual) && Math.abs(actual - target) < 0.5;
  };

  function checkPending() {
    for (const [name, entry] of [...pending]) {
      if (!entry.sent || !matches(name, entry.target)) continue;
      pending.delete(name);
      setWriteStatus(`${entry.label}: confirmed by the model after ${((performance.now() - entry.since) / 1000).toFixed(1)} s (dashboard, Xentara, Modbus device and back).`, 'ok');
    }
  }

  async function send(name, target, label) {
    if (!source) { setWriteStatus('Not connected: connect to Xentara or start the demo first.', 'fail'); return; }
    const command = WRITE_ONLY.includes(name);
    if (!command) pending.set(name, { target, label, since: performance.now(), sent: false });
    setWriteStatus(`${label}: sending ...`);
    try {
      await source.write(name, target);
      if (command) setWriteStatus(`${label}: sent.`, 'ok');
      else if (pending.has(name)) { pending.get(name).sent = true; checkPending(); }
    } catch (error) {
      pending.delete(name);
      setWriteStatus(error.message || String(error), 'fail');
      dirty = true;
    }
  }

  async function scenario(kind) {
    if (kind === 'fill') { await send('Auto Mode', true, 'Automatic control on'); await send('Level Setpoint', 80, 'Set point 80 %'); }
    if (kind === 'drain') { await send('Auto Mode', true, 'Automatic control on'); await send('Level Setpoint', 20, 'Set point 20 %'); }
    if (kind === 'overfill') {
      await send('Auto Mode', false, 'Automatic control off');
      await send('Pump Speed', 100, 'Pump speed 100 %');
      await send('Pump Enable', true, 'Pump on');
    }
    if (kind === 'reset') {
      await send('Pump Enable', false, 'Pump off');
      await send('Pump Speed', 60, 'Pump speed 60 %');
      await send('Level Setpoint', 50, 'Set point 50 %');
      await send('Auto Mode', true, 'Automatic control on');
    }
  }

  function wireControls() {
    $('in-setpoint').addEventListener('input', (e) => { $('out-setpoint').textContent = e.target.value; });
    $('in-setpoint').addEventListener('change', (e) => send('Level Setpoint', Number(e.target.value), `Set point ${e.target.value} %`));
    $('in-speed').addEventListener('input', (e) => { $('out-speed').textContent = e.target.value; });
    $('in-speed').addEventListener('change', (e) => send('Pump Speed', Number(e.target.value), `Pump speed ${e.target.value} %`));
    $('in-auto').addEventListener('change', (e) => { send('Auto Mode', e.target.checked, e.target.checked ? 'Automatic control on' : 'Automatic control off'); dirty = true; });
    $('in-enable').addEventListener('change', (e) => send('Pump Enable', e.target.checked, e.target.checked ? 'Pump on' : 'Pump off'));
    $('ack-button').addEventListener('click', () => send('Alarm Acknowledge', true, 'Acknowledge alarms'));
    for (const button of document.querySelectorAll('[data-scenario]')) button.addEventListener('click', () => scenario(button.dataset.scenario));
  }

  // ------------------------------------------------------------------------------------------------ connection
  function onStatus(state, text) {
    live = state === 'live';
    $('status').dataset.state = state;
    $('status').textContent = state === 'live' ? text : state === 'connecting' ? 'Connecting ...' : state === 'error' ? 'Error' : state === 'disconnected' ? 'Disconnected' : text;
    const error = $('error');
    error.hidden = state !== 'error' && !(state === 'disconnected' && text && text !== 'Disconnected.');
    error.textContent = error.hidden ? '' : text;
    if (live) { $('connect').hidden = true; $('connection-toggle').setAttribute('aria-expanded', 'false'); }
    dirty = true;
  }

  function stopSource() {
    if (source) { try { source.close(); } catch (e) { /* ignore */ } }
    source = null;
    pending.clear();
    snapshot = {};
    history.length = 0;
    displayLevel = null;
    live = false;
  }

  function connectLive(host, user, password) {
    stopSource();
    rememberInputs(host, user);
    source = new Xentara.XentaraClient({
      host, user, password, prefix: 'Plant.', names: NAMES, writeOnlyNames: WRITE_ONLY, onStatus,
      onValues: (values) => { snapshot = values; dirty = true; checkPending(); },
    });
    return source.connect().catch(() => {});
  }

  function startDemo(speed) {
    stopSource();
    source = new Mock.MockSource({ speed: speed || 1, onStatus, onValues: (values) => { snapshot = values; dirty = true; checkPending(); } });
    return source.connect();
  }

  function rememberInputs(host, user) {
    try { localStorage.setItem('tank-dashboard', JSON.stringify({ host, user })); } catch (e) { /* storage may be blocked */ }
  }

  function restoreInputs() {
    try {
      const saved = JSON.parse(localStorage.getItem('tank-dashboard') || '{}');
      if (saved.host) $('host').value = saved.host;
      if (saved.user) $('user').value = saved.user;
    } catch (e) { /* ignore */ }
  }

  function wireConnection() {
    const params = new URLSearchParams(location.search);
    if (params.get('host')) $('host').value = params.get('host');
    else if (location.hostname && location.protocol !== 'file:') $('host').value = `${location.hostname}:19670`;
    restoreInputs();
    $('origin').textContent = location.origin === 'null' ? 'null (file://), use http://localhost:8080 instead' : location.origin;
    const updateLink = () => { $('cert-link').href = `https://${$('host').value.trim()}`; $('cert-link').textContent = `https://${$('host').value.trim()}`; };
    $('host').addEventListener('input', updateLink);
    updateLink();

    $('connect-form').addEventListener('submit', (e) => { e.preventDefault(); connectLive($('host').value.trim(), $('user').value.trim(), $('password').value); });
    $('demo-button').addEventListener('click', () => startDemo());
    $('disconnect-button').addEventListener('click', () => { stopSource(); onStatus('idle', 'Not connected'); $('connect').hidden = false; });
    $('connection-toggle').addEventListener('click', () => {
      const hidden = !$('connect').hidden;
      $('connect').hidden = hidden;
      $('connection-toggle').setAttribute('aria-expanded', String(!hidden));
    });

    if (params.get('demo')) startDemo(Number(params.get('speed')) || 1);
  }

  // ------------------------------------------------------------------------------------------------ start
  function start() {
    drawScale();
    drawTrend();
    wireControls();
    wireConnection();
    setInterval(sample, 1000);
    requestAnimationFrame(frame);
    // a small API for tests and for the browser's console
    window.lab = { connectLive, startDemo, send, stop: stopSource, snapshot: () => snapshot, history, pending, source: () => source };
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
