// A client for the Xentara WebSocket interface (docs.xentara.io/xentara-websocket-api/, protocol version 1).
//
//   1. POST https://host:port/api/v1/request-token  (Authorization: Basic ...)  ->  a short-lived token (20 s)
//   2. wss://host:port/api/ws?token=...               every message is one CBOR array of packets
//   3. client hello, then per data point: lookup (primary key -> UUID), metadata (data type), subscribe
//
// Packets: request [0, id, opCode, {params}], success [1, id, result], error [2, id, {0: code, 1: message}],
// event [8, 0, {0: time, 1: element UUID, 2: {attribute id: 121(value) | 122(error)}}]. Maps have integer keys.
(function (root) {
  'use strict';
  const Cbor = typeof require === 'function' ? require('./cbor.js') : root.Cbor;

  const OP = { metadata: 2, lookup: 3, read: 4, write: 5, subscribe: 6, unsubscribe: 7, hello: 14 };
  const ATTRIBUTE = { name: 1, quality: 9, value: 11 };
  const TYPE_BOOLEAN = 0;
  const TYPE_INTEGERS = [1, 2, 3, 4, 5, 6, 7, 8];
  const TYPE_FLOATS = [9, 10];

  class XentaraError extends Error {
    constructor(message, code, hint) {
      super(message);
      this.name = 'XentaraError';
      this.code = code;
      this.hint = hint;
    }
  }

  const ERROR_TEXT = {
    '-32100': 'unknown element',
    '-32101': 'missing attribute',
    '-32102': 'access denied (the user needs the "websocket.connect" and write entitlements)',
    '-32103': 'the value is read only',
    '-32105': 'value out of range',
    '-32106': 'wrong data type',
    '-32107': 'illegal value',
    '-32109': 'write error',
  };

  class XentaraClient {
    /**
     * @param {object} options
     *   host, user, password   where to connect ("host:19670") and who
     *   prefix                 primary key prefix of the data points, e.g. "Plant."
     *   names                  the data point names to subscribe to, e.g. ["Tank Level", "Pump Speed"]
     *   writeOnlyNames         data points that are only written, e.g. a command: looked up, but not subscribed
     *   onStatus(status, text) "connecting" | "live" | "disconnected" | "error"
     *   onValues(snapshot)     snapshot = { name: { value, quality, time } }
     *   onLog(text)            optional
     *   WebSocketImpl, fetchImpl   for tests
     */
    constructor(options) {
      this.options = Object.assign({ prefix: 'Plant.', names: [], writeOnlyNames: [], onStatus() {}, onValues() {}, onLog() {} }, options);
      this.WS = options.WebSocketImpl || (typeof WebSocket !== 'undefined' ? WebSocket : undefined);
      this.fetch = options.fetchImpl || (typeof fetch !== 'undefined' ? fetch.bind(globalThis) : undefined);
      this.state = {};
      this.elements = new Map(); // uuid hex -> name
      this.byName = new Map(); // name -> { uuid: Tagged, type }
      this.pending = new Map();
      this.nextId = 1;
      this.ws = null;
      this.closedByUser = false;
      this.retryDelay = 2000;
    }

    log(text) {
      this.options.onLog(text);
    }

    status(status, text) {
      this.options.onStatus(status, text);
    }

    // -------------------------------------------------------------------------------------------- connecting
    async connect() {
      this.closedByUser = false;
      this.status('connecting', `Connecting to ${this.options.host} ...`);
      try {
        const token = await this.requestToken();
        await this.openSocket(token);
        await this.request(OP.hello, new Map([[0, 0], [1, 1]]));
        await this.subscribeAll();
        this.retryDelay = 2000;
        this.status('live', `Live: ${this.options.host}`);
      } catch (error) {
        this.cleanup();
        const hint = error.hint ? ' ' + error.hint : '';
        this.status('error', `${error.message}${hint}`);
        this.scheduleReconnect();
        throw error;
      }
    }

    async requestToken() {
      const base = `https://${this.options.host}`;
      let response;
      try {
        response = await this.fetch(`${base}/api/v1/request-token`, {
          method: 'POST',
          headers: { Authorization: 'Basic ' + toBase64(`${this.options.user}:${this.options.password}`) },
        });
      } catch (error) {
        throw new XentaraError(
          `Cannot reach ${this.options.host}.`,
          undefined,
          `Open ${base} once in this browser and accept the self-signed certificate. ` +
            `Also check that "httpServer.CORS.allowedOrigins" in Xentara's config.json contains this page's origin ` +
            `(${typeof location !== 'undefined' ? location.origin : 'the origin of this page'}) and that Xentara is running.`,
        );
      }
      if (response.status === 401) {
        const password = this.options.password || '';
        const spaces = password !== password.trim() ? ' The password starts or ends with a space.' : '';
        throw new XentaraError(
          `Login refused (401) for user "${this.options.user}" with a password of ${password.length} characters.${spaces}`,
          401,
          'If that is not what you typed, the browser may have filled in a saved password. Otherwise check the user name and password (xentara-password), ' +
            'that the user is listed in users.json with a password in passwords.json, and that "httpServer.authentication.schemes" in config.json includes "Basic". ' +
            'To test without the browser: curl -sk -u <user> -X POST https://' + this.options.host + '/api/v1/request-token',
        );
      }
      if (response.status === 404) throw new XentaraError('This Xentara has no token endpoint (Xentara 2.0?).', 404);
      if (!response.ok) throw new XentaraError(`The token request failed: HTTP ${response.status}.`, response.status);
      return parseToken(await response.text());
    }

    openSocket(token) {
      return new Promise((resolve, reject) => {
        const ws = new this.WS(`wss://${this.options.host}/api/ws?token=${encodeURIComponent(token)}`);
        ws.binaryType = 'arraybuffer';
        let opened = false;
        ws.onopen = () => {
          opened = true;
          resolve();
        };
        ws.onmessage = (event) => this.onMessage(event.data);
        ws.onerror = () => {
          if (!opened) reject(new XentaraError('The WebSocket connection was refused.', undefined, 'The token is only valid for 20 seconds, or the user may lack the "websocket.connect" entitlement.'));
        };
        ws.onclose = () => {
          const wasLive = opened;
          this.cleanup();
          if (!opened) return;
          if (wasLive && !this.closedByUser) {
            this.status('disconnected', 'Connection lost. Reconnecting ...');
            this.scheduleReconnect();
          }
        };
        this.ws = ws;
      });
    }

    cleanup() {
      for (const { reject } of this.pending.values()) reject(new XentaraError('Connection closed.'));
      this.pending.clear();
      if (this.ws) {
        const ws = this.ws;
        this.ws = null;
        ws.onclose = ws.onerror = ws.onmessage = null;
        try { ws.close(); } catch (e) { /* already closed */ }
      }
    }

    scheduleReconnect() {
      if (this.closedByUser || this.retryTimer) return;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        this.retryDelay = Math.min(this.retryDelay * 1.5, 10000);
        this.connect().catch(() => {});
      }, this.retryDelay);
    }

    close() {
      this.closedByUser = true;
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
      this.cleanup();
      this.status('disconnected', 'Disconnected.');
    }

    // -------------------------------------------------------------------------------------------- requests
    request(opCode, params) {
      return new Promise((resolve, reject) => {
        if (!this.ws) return reject(new XentaraError('Not connected.'));
        const id = this.nextId++;
        const timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new XentaraError(`No answer to request ${id} (opcode ${opCode}).`));
        }, 10000);
        this.pending.set(id, {
          resolve: (value) => { clearTimeout(timer); resolve(value); },
          reject: (error) => { clearTimeout(timer); reject(error); },
        });
        this.ws.send(Cbor.encode([[0, id, opCode, params]]));
      });
    }

    onMessage(data) {
      let packets;
      try {
        packets = Cbor.decode(new Uint8Array(data));
      } catch (error) {
        this.log('Cannot decode a message: ' + error.message);
        return;
      }
      for (const packet of packets) {
        const type = packet[0];
        if (type === 1) {
          const entry = this.pending.get(packet[1]);
          if (entry) { this.pending.delete(packet[1]); entry.resolve(packet[2]); }
        } else if (type === 2) {
          const details = packet[2] instanceof Map ? packet[2] : new Map();
          const code = details.get(0);
          const text = `${details.get(1) || ERROR_TEXT[code] || 'error'} (${code})`;
          const entry = this.pending.get(packet[1]);
          if (entry) { this.pending.delete(packet[1]); entry.reject(new XentaraError(text, code)); }
          else this.log('Error from Xentara: ' + text);
        } else if (type === 8) {
          this.onEvent(packet);
        }
      }
    }

    // -------------------------------------------------------------------------------------------- data points
    async subscribeAll() {
      this.state = {};
      this.elements.clear();
      this.byName.clear();
      const subscription = [];
      for (const name of [...this.options.names, ...this.options.writeOnlyNames]) {
        const key = this.options.prefix + name;
        let uuid;
        try {
          uuid = await this.request(OP.lookup, new Map([[0, key]]));
        } catch (error) {
          throw new XentaraError(`Xentara has no element "${key}" (${error.message}). Is the model loaded?`, error.code);
        }
        const meta = await this.request(OP.metadata, new Map([[0, uuid], [1, [2]]]));
        const attributes = (meta.get(2) || []).filter((a) => a instanceof Map);
        const value = attributes.find((a) => a.get(1) === ATTRIBUTE.value);
        this.byName.set(name, { uuid, type: value ? value.get(3) : undefined });
        if (this.options.writeOnlyNames.includes(name)) continue;
        this.elements.set(Cbor.uuidHex(uuid), name);
        subscription.push(new Map([[0, uuid], [1, [ATTRIBUTE.value, ATTRIBUTE.quality]]]));
      }
      // the answer is followed by an event with the current values
      await this.request(OP.subscribe, new Map([[0, subscription], [1, 100], [2, 2000]]));
    }

    onEvent(packet) {
      const body = packet[2];
      if (!(body instanceof Map)) return;
      const uuid = body.get(1);
      const name = uuid && uuid.tag === 37 ? this.elements.get(Cbor.uuidHex(uuid)) : undefined;
      if (!name) return;
      const entry = this.state[name] || (this.state[name] = { value: undefined, quality: undefined, time: undefined });
      for (const [attribute, wrapped] of body.get(2) || []) {
        const data = wrapped instanceof Cbor.Tagged ? wrapped : { tag: 121, value: wrapped };
        if (data.tag === 122) continue; // an error for this attribute
        if (attribute === ATTRIBUTE.value) entry.value = unwrap(data.value);
        if (attribute === ATTRIBUTE.quality) entry.quality = unwrap(data.value);
      }
      entry.time = Date.now();
      this.options.onValues(this.snapshot());
    }

    snapshot() {
      const copy = {};
      for (const name of Object.keys(this.state)) copy[name] = Object.assign({}, this.state[name]);
      return copy;
    }

    /** Writes the value of a data point. The value is sent as the data type of the attribute (from the metadata). */
    async write(name, value) {
      const entry = this.byName.get(name);
      if (!entry) throw new XentaraError(`Unknown data point "${name}".`);
      const params = new Map([[0, entry.uuid], [1, ATTRIBUTE.value], [2, coerce(value, entry.type)]]);
      try {
        await this.request(OP.write, params);
      } catch (error) {
        if (error.code in ERROR_TEXT) error.message = `Writing ${name}: ${ERROR_TEXT[error.code]} (${error.code})`;
        throw error;
      }
    }
  }

  // ---------------------------------------------------------------------------------------------- helpers
  function toBase64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (const b of bytes) binary += String.fromCharCode(b);
    return btoa(binary);
  }

  /** The token endpoint's response format is not documented: accept JSON with a token field, a JSON string, or plain text */
  function parseToken(text) {
    const trimmed = text.trim();
    try {
      const json = JSON.parse(trimmed);
      if (typeof json === 'string') return json;
      if (json && typeof json === 'object') {
        for (const key of ['token', 'access_token', 'accessToken']) if (typeof json[key] === 'string') return json[key];
      }
    } catch (e) { /* plain text */ }
    if (!trimmed) throw new XentaraError('The token endpoint returned an empty response.');
    return trimmed;
  }

  function unwrap(value) {
    return typeof value === 'bigint' ? Number(value) : value;
  }

  /** Converts a JavaScript value to what the attribute's data type expects */
  function coerce(value, type) {
    if (type === TYPE_BOOLEAN) return Boolean(value);
    if (TYPE_INTEGERS.includes(type)) return Math.round(Number(value));
    if (TYPE_FLOATS.includes(type)) return Cbor.float(value); // 70 must be sent as 70.0, not as the integer 70
    return value;
  }

  const api = { XentaraClient, XentaraError, parseToken, coerce, OP, ATTRIBUTE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Xentara = api;
})(typeof self !== 'undefined' ? self : this);
