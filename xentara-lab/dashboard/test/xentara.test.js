// The Xentara client against a fake Xentara (an in-process WebSocket and fetch that speak the documented protocol).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Cbor = require('../cbor.js');
const { XentaraClient, XentaraError, parseToken, coerce } = require('../xentara.js');

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');

/** A fake Xentara with a few data points */
class FakeXentara {
  constructor() {
    this.points = new Map(); // primary key -> { uuid, type, value, quality }
    this.add('Plant.Tank Level', 10, 45.6);
    this.add('Plant.Pump Speed', 6, 60); // uint16
    this.add('Plant.Auto Mode', 0, true); // boolean
    this.add('Plant.Alarm Acknowledge', 0, false); // write only command
    this.sockets = [];
    this.tokenRequests = [];
    this.writes = [];
    this.rawWrites = [];
    this.helloCount = 0;
    this.users = { admin: 'secret' };
    this.failWriteWith = null;
  }

  add(key, type, value) {
    const n = this.points.size + 1;
    this.points.set(key, { uuid: '00000000000000000000000000' + String(n).padStart(6, '0'), type, value, quality: 0 });
  }

  byUuid(tagged) {
    const id = Cbor.uuidHex(tagged);
    return [...this.points.values()].find((p) => p.uuid === id);
  }

  fetch = async (url, options) => {
    this.tokenRequests.push({ url, options });
    const auth = (options.headers || {}).Authorization || '';
    const [user, password] = Buffer.from(auth.replace('Basic ', ''), 'base64').toString().split(':');
    if (this.users[user] !== password) return { status: 401, ok: false, text: async () => 'authorization required' };
    return { status: 200, ok: true, text: async () => JSON.stringify({ token: 'tok-' + this.tokenRequests.length }) };
  };

  WebSocket = (server) =>
    class FakeSocket {
      constructor(url) {
        this.url = url;
        this.sent = [];
        server.sockets.push(this);
        setTimeout(() => this.onopen && this.onopen(), 0);
      }

      send(bytes) {
        for (const packet of Cbor.decode(bytes)) setTimeout(() => this.handle(packet, bytes), 0);
      }

      reply(packets) {
        const bytes = Cbor.encode(packets);
        this.onmessage({ data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
      }

      handle([type, id, op, params], raw) {
        if (op === 14) {
          server.helloCount++;
          return this.reply([[1, id, new Map([[0, 1]])]]);
        }
        if (op === 3) {
          const p = server.points.get(params.get(0));
          return p ? this.reply([[1, id, Cbor.uuid(p.uuid)]]) : this.reply([[2, id, new Map([[0, -32100], [1, 'unknown element']])]]);
        }
        if (op === 2) {
          const p = server.byUuid(params.get(0));
          const attributes = [new Map([[0, 'name', ], [1, 1], [2, 1], [3, 13]]), new Map([[0, 'value'], [1, 11], [2, 2], [3, p.type]])];
          return this.reply([[1, id, new Map([[2, attributes]])]]);
        }
        if (op === 6) {
          this.subscription = params.get(0);
          this.reply([[1, id, Cbor.uuid('11111111111111111111111111111111')]]);
          for (const item of this.subscription) this.event(server.byUuid(item.get(0)));
          return undefined;
        }
        if (op === 5) {
          const p = server.byUuid(params.get(0));
          server.rawWrites.push(hex(raw));
          if (server.failWriteWith) return this.reply([[2, id, new Map([[0, server.failWriteWith], [1, 'nope']])]]);
          p.value = params.get(2);
          server.writes.push({ key: [...server.points].find(([, v]) => v === p)[0], attribute: params.get(1), value: params.get(2) });
          this.reply([[1, id]]);
          return this.event(p);
        }
        return this.reply([[2, id, new Map([[0, -32601], [1, 'command not found']])]]);
      }

      event(p) {
        this.reply([[8, 0, new Map([
          [0, new Cbor.Tagged(1, 1764061200.5)],
          [1, Cbor.uuid(p.uuid)],
          [2, new Map([[11, new Cbor.Tagged(121, p.value)], [9, new Cbor.Tagged(121, p.quality)]])],
        ])]]);
      }

      close() {
        this.closed = true;
      }
    };
}

function makeClient(server, extra = {}) {
  const log = { statuses: [], values: [] };
  const client = new XentaraClient(Object.assign({
    host: 'xentara.test:19670',
    user: 'admin',
    password: 'secret',
    names: ['Tank Level', 'Pump Speed', 'Auto Mode'],
    fetchImpl: server.fetch,
    WebSocketImpl: server.WebSocket(server),
    onStatus: (status, text) => log.statuses.push([status, text]),
    onValues: (snapshot) => log.values.push(snapshot),
  }, extra));
  return { client, log };
}

test('connects, subscribes and reports the current values', async () => {
  const server = new FakeXentara();
  const { client, log } = makeClient(server);
  await client.connect();

  assert.equal(server.tokenRequests[0].url, 'https://xentara.test:19670/api/v1/request-token');
  assert.equal(server.tokenRequests[0].options.method, 'POST');
  assert.equal(server.tokenRequests[0].options.headers.Authorization, 'Basic ' + Buffer.from('admin:secret').toString('base64'));
  assert.equal(server.sockets[0].url, 'wss://xentara.test:19670/api/ws?token=tok-1');
  assert.equal(server.helloCount, 1);
  assert.deepEqual(log.statuses.map((s) => s[0]), ['connecting', 'live']);

  const last = log.values[log.values.length - 1];
  assert.deepEqual(last['Tank Level'].value, 45.6);
  assert.equal(last['Pump Speed'].value, 60);
  assert.equal(last['Auto Mode'].value, true);
  assert.equal(last['Tank Level'].quality, 0);
  client.close();
});

test('values are sent as the data type of the attribute', async () => {
  const server = new FakeXentara();
  const { client } = makeClient(server);
  await client.connect();

  await client.write('Pump Speed', 80.4); // uint16: an integer
  await client.write('Tank Level', 70); // float64: a float, although the value is a whole number
  await client.write('Auto Mode', 0); // boolean

  assert.deepEqual(server.writes.map((w) => [w.key, w.attribute, w.value]), [
    ['Plant.Pump Speed', 11, 80],
    ['Plant.Tank Level', 11, 70],
    ['Plant.Auto Mode', 11, false],
  ]);
  assert.ok(server.rawWrites[1].includes('fb4051800000000000'), '70 is encoded as the float 70.0');
  assert.ok(!server.rawWrites[0].includes('fb'), 'the integer attribute gets an integer');
  assert.ok(server.rawWrites[2].includes('f4'), 'false');
  client.close();
});

test('a write is answered by an event with the new value', async () => {
  const server = new FakeXentara();
  const { client, log } = makeClient(server);
  await client.connect();
  await client.write('Pump Speed', 25);
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(log.values[log.values.length - 1]['Pump Speed'].value, 25);
  client.close();
});

test('errors are reported with a readable message', async () => {
  const server = new FakeXentara();
  const { client } = makeClient(server);
  await client.connect();
  server.failWriteWith = -32103;
  await assert.rejects(client.write('Pump Speed', 1), (e) => e instanceof XentaraError && /read only/.test(e.message) && e.code === -32103);
  server.failWriteWith = -32102;
  await assert.rejects(client.write('Pump Speed', 1), /access denied/);
  await assert.rejects(client.write('Nothing', 1), /Unknown data point/);
  client.close();
});

test('a wrong password is explained', async () => {
  const server = new FakeXentara();
  const { client, log } = makeClient(server, { password: 'wrong' });
  await assert.rejects(client.connect(), (e) => e.code === 401 && /Basic/.test(e.hint) && /curl/.test(e.hint));
  assert.equal(log.statuses[log.statuses.length - 1][0], 'error');
  const message = log.statuses[log.statuses.length - 1][1];
  assert.match(message, /Login refused \(401\) for user "admin" with a password of 5 characters/);
  assert.ok(!message.includes('wrong'), 'the password itself is never shown');
  client.close();
});

test('an unreachable server is explained with certificate and CORS hints', async () => {
  const server = new FakeXentara();
  const { client } = makeClient(server, { fetchImpl: async () => { throw new TypeError('Failed to fetch'); } });
  await assert.rejects(client.connect(), (e) => /certificate/.test(e.hint) && /allowedOrigins/.test(e.hint));
  client.close();
});

test('a missing data point names the primary key', async () => {
  const server = new FakeXentara();
  const { client } = makeClient(server, { names: ['Tank Level', 'Does Not Exist'] });
  await assert.rejects(client.connect(), /no element "Plant.Does Not Exist"/);
  client.close();
});

test('the token response may be JSON or plain text', () => {
  assert.equal(parseToken('{"token":"abc"}'), 'abc');
  assert.equal(parseToken('"abc"'), 'abc');
  assert.equal(parseToken('abc\n'), 'abc');
  assert.equal(parseToken('{"access_token":"xyz"}'), 'xyz');
  assert.throws(() => parseToken('   '), /empty/);
});

test('coerce follows the data type identifiers of the protocol', () => {
  assert.equal(coerce(1, 0), true);
  assert.equal(coerce(70.6, 6), 71);
  assert.equal(coerce('5', 4), 5);
  assert.equal(hex(Cbor.encode(coerce(70, 10))), 'fb4051800000000000');
  assert.equal(hex(Cbor.encode(coerce(70, 9))), 'fb4051800000000000');
  assert.equal(coerce('text', 13), 'text');
});

test('a write-only data point can be written but is not subscribed', async () => {
  const server = new FakeXentara();
  const { client, log } = makeClient(server, { writeOnlyNames: ['Alarm Acknowledge'] });
  await client.connect();
  assert.equal(client.subscribedCount, undefined);
  const last = log.values[log.values.length - 1];
  assert.ok(!('Alarm Acknowledge' in last), 'no value is reported for it');
  await client.write('Alarm Acknowledge', true);
  assert.deepEqual(server.writes.map((w) => [w.key, w.value]), [['Plant.Alarm Acknowledge', true]]);
  client.close();
});

test('a password with leading or trailing space is pointed out', async () => {
  const server = new FakeXentara();
  const { client, log } = makeClient(server, { password: 'secret ' });
  await assert.rejects(client.connect(), (e) => e.code === 401);
  assert.match(log.statuses[log.statuses.length - 1][1], /starts or ends with a space/);
  client.close();
});
