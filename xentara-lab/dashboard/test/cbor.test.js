// node --test dashboard/test/
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Cbor = require('../cbor.js');

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
const fromHex = (h) => Uint8Array.from(h.match(/../g), (x) => parseInt(x, 16));

test('integers: the examples of RFC 8949 appendix A', () => {
  const cases = [[0, '00'], [1, '01'], [10, '0a'], [23, '17'], [24, '1818'], [25, '1819'], [100, '1864'], [1000, '1903e8'],
    [1000000, '1a000f4240'], [4294967295, '1affffffff'], [4294967296, '1b0000000100000000'],
    [-1, '20'], [-10, '29'], [-100, '3863'], [-1000, '3903e7']];
  for (const [value, expected] of cases) {
    assert.equal(hex(Cbor.encode(value)), expected, `encode ${value}`);
    assert.equal(Cbor.decode(fromHex(expected)), value, `decode ${expected}`);
  }
});

test('big integers stay exact', () => {
  assert.equal(hex(Cbor.encode(18446744073709551615n)), '1bffffffffffffffff');
  assert.equal(Cbor.decode(fromHex('1bffffffffffffffff')), 18446744073709551615n);
  assert.equal(Cbor.decode(fromHex('3bffffffffffffffff')), -18446744073709551616n);
  assert.equal(Cbor.decode(fromHex('1b0000000100000000')), 4294967296, 'safe integers come back as numbers');
});

test('floats: encoded as float64, decoded from 16, 32 and 64 bit', () => {
  assert.equal(hex(Cbor.encode(1.1)), 'fb3ff199999999999a');
  assert.equal(Cbor.decode(fromHex('fb3ff199999999999a')), 1.1);
  assert.equal(Cbor.decode(fromHex('f93c00')), 1.0);
  assert.equal(Cbor.decode(fromHex('f97bff')), 65504.0);
  assert.equal(Cbor.decode(fromHex('f9c400')), -4.0);
  assert.equal(Cbor.decode(fromHex('fa47c35000')), 100000.0);
  assert.equal(Cbor.decode(fromHex('fa7f800000')), Infinity);
  assert.ok(Number.isNaN(Cbor.decode(fromHex('f97e00'))));
  assert.equal(Cbor.decode(Cbor.encode(25.98)), 25.98);
});

test('strings, bytes, simple values', () => {
  assert.equal(hex(Cbor.encode('IETF')), '6449455446');
  assert.equal(Cbor.decode(fromHex('6449455446')), 'IETF');
  assert.equal(Cbor.decode(Cbor.encode('Grad Celsius: °C, ü, 水')), 'Grad Celsius: °C, ü, 水');
  assert.deepEqual(Array.from(Cbor.decode(fromHex('4401020304'))), [1, 2, 3, 4]);
  assert.equal(hex(Cbor.encode(true)), 'f5');
  assert.equal(hex(Cbor.encode(false)), 'f4');
  assert.equal(hex(Cbor.encode(null)), 'f6');
  assert.equal(Cbor.decode(fromHex('f5')), true);
  assert.equal(Cbor.decode(fromHex('f6')), null);
});

test('arrays and maps (integer keys stay integers)', () => {
  assert.equal(hex(Cbor.encode([1, 2, 3])), '83010203');
  assert.deepEqual(Cbor.decode(fromHex('83010203')), [1, 2, 3]);
  const map = new Map([[0, 0], [1, 1]]);
  assert.equal(hex(Cbor.encode(map)), 'a200000101');
  const decoded = Cbor.decode(fromHex('a200000101'));
  assert.ok(decoded instanceof Map);
  assert.equal(decoded.get(1), 1);
  assert.equal(hex(Cbor.encode({ a: 1, b: [2, 3] })), 'a26161016162820203');
  assert.equal(Cbor.decode(fromHex('a26161016162820203')).get('b')[1], 3);
});

test('indefinite lengths', () => {
  assert.deepEqual(Cbor.decode(fromHex('9f018202039f0405ffff')), [1, [2, 3], [4, 5]]);
  assert.equal(Cbor.decode(fromHex('7f657374726561646d696e67ff')), 'streaming');
});

test('tags and UUIDs', () => {
  const id = 'e3ee10714d884ba18e5d0f1e4ce25ee8';
  const encoded = Cbor.encode(Cbor.uuid(id));
  assert.equal(hex(encoded), 'd825' + '50' + id);
  const decoded = Cbor.decode(encoded);
  assert.equal(decoded.tag, 37);
  assert.equal(Cbor.uuidHex(decoded), id);
  assert.equal(Cbor.uuidHex(Cbor.decode(Cbor.encode(Cbor.uuid('E3EE1071-4D88-4BA1-8E5D-0F1E4CE25EE8')))), id);
  assert.throws(() => Cbor.uuid('nope'));
  const success = Cbor.decode(Cbor.encode(new Cbor.Tagged(121, 25.98)));
  assert.equal(success.tag, 121);
  assert.equal(success.value, 25.98);
});

test('malformed input is rejected', () => {
  assert.throws(() => Cbor.decode(fromHex('83010203' + '00')), /unexpected bytes/);
  assert.throws(() => Cbor.decode(fromHex('8301')), /unexpected end/);
  assert.throws(() => Cbor.decode(fromHex('62c328')), /./); // invalid UTF-8
  assert.throws(() => Cbor.decode(new Uint8Array(0)), /unexpected end/);
});

// ---------------------------------------------------------------- the messages in the Xentara WebSocket API specification
test('spec: client hello request and response', () => {
  // [[0, 65, 14, {0: 0, 1: 1}]]  (every message is wrapped in an outer array)
  const request = Cbor.encode([[0, 65, 14, new Map([[0, 0], [1, 1]])]]);
  assert.equal(hex(request), '8184001841' + '0e' + 'a200000101');
  const response = Cbor.decode(Cbor.encode([[1, 65, new Map([[0, 1]])]]));
  assert.equal(response[0][0], 1);
  assert.equal(response[0][2].get(0), 1);
});

test('spec: a read response with a success and an error value', () => {
  const message = [[1, 65, new Map([
    [1, new Cbor.Tagged(121, 'register')],
    [11, new Cbor.Tagged(121, true)],
    [12, new Cbor.Tagged(122, new Map([[0, -32101], [1, 'missing attribute']]))],
  ])]];
  const decoded = Cbor.decode(Cbor.encode(message));
  const values = decoded[0][2];
  assert.equal(values.get(11).tag, 121);
  assert.equal(values.get(11).value, true);
  assert.equal(values.get(12).tag, 122);
  assert.equal(values.get(12).value.get(0), -32101);
});

test('spec: a data change event with a nanosecond time stamp and an element UUID', () => {
  const event = [[8, 0, new Map([
    [0, new Cbor.Tagged(1, new Cbor.Tagged(4, [-9, 179998887776665]))],
    [1, Cbor.uuid('B24A0000000000000000000000000001')],
    [2, new Map([[11, new Cbor.Tagged(121, 25.98)], [9, new Cbor.Tagged(121, 0)]])],
  ])]];
  const decoded = Cbor.decode(Cbor.encode(event));
  const packet = decoded[0];
  assert.equal(packet[0], 8);
  assert.equal(Cbor.uuidHex(packet[2].get(1)), 'b24a0000000000000000000000000001');
  assert.equal(packet[2].get(2).get(11).value, 25.98);
  assert.equal(packet[2].get(0).tag, 1);
});

test('a time stamp of the current real time does not fit a double and is kept as a bigint', () => {
  const nanoseconds = 1764061200123456789n;
  const decoded = Cbor.decode(Cbor.encode(new Cbor.Tagged(1001, new Map([[4, new Cbor.Tagged(4, [-9, nanoseconds])]]))));
  assert.equal(decoded.value.get(4).value[1], nanoseconds);
});

test('Cbor.float forces a float encoding for whole numbers', () => {
  assert.equal(hex(Cbor.encode(70)), '1846');
  assert.equal(hex(Cbor.encode(Cbor.float(70))), 'fb4051800000000000');
  assert.equal(Cbor.decode(Cbor.encode(Cbor.float(70))), 70);
});
