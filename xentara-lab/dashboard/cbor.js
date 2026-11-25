// A small CBOR (RFC 8949) encoder and decoder, enough for the Xentara WebSocket interface. No dependencies.
//
//   JavaScript                 CBOR
//   number (integer)           unsigned / negative integer
//   number (non-integer)       float64
//   Cbor.float(70)             float64 even if the value is a whole number (for attributes of a floating point type)
//   bigint                     integer beyond 2^53
//   string                     text string
//   Uint8Array                 byte string
//   Array                      array
//   Map                        map (keys can be numbers: the Xentara protocol uses integer keys)
//   plain object               map with text keys (encode) -> decoded as Map
//   Tagged(tag, value)         tagged value (UUID = tag 37, success = 121, error = 122, time = 1001, ...)
//   true / false / null        simple values
//
// Decoded maps are always Map objects, so that integer keys stay integers.
(function (root) {
  'use strict';

  class Tagged {
    constructor(tag, value) {
      this.tag = tag;
      this.value = value;
    }
  }

  /** Forces a number to be encoded as a float, not as an integer */
  class Float {
    constructor(value) {
      this.value = value;
    }
  }

  const textEncoder = new TextEncoder();
  const textDecoder = new TextDecoder('utf-8', { fatal: true });

  // ------------------------------------------------------------------------------------------------ encoding
  function encode(value) {
    const chunks = [];
    write(value, chunks);
    let length = 0;
    for (const c of chunks) length += c.length;
    const out = new Uint8Array(length);
    let offset = 0;
    for (const c of chunks) {
      out.set(c, offset);
      offset += c.length;
    }
    return out;
  }

  function head(major, n, chunks) {
    // n is a non-negative integer (number or bigint)
    const m = major << 5;
    if (n < 24) chunks.push(Uint8Array.of(m | Number(n)));
    else if (n < 0x100) chunks.push(Uint8Array.of(m | 24, Number(n)));
    else if (n < 0x10000) chunks.push(Uint8Array.of(m | 25, Number(n) >> 8, Number(n) & 0xff));
    else if (n < 0x100000000) {
      const v = Number(n);
      chunks.push(Uint8Array.of(m | 26, (v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff));
    } else {
      const b = new Uint8Array(9);
      b[0] = m | 27;
      new DataView(b.buffer).setBigUint64(1, BigInt(n));
      chunks.push(b);
    }
  }

  function write(value, chunks) {
    if (value === null || value === undefined) {
      chunks.push(Uint8Array.of(value === null ? 0xf6 : 0xf7));
    } else if (value === true || value === false) {
      chunks.push(Uint8Array.of(value ? 0xf5 : 0xf4));
    } else if (value instanceof Float) {
      const b = new Uint8Array(9);
      b[0] = 0xfb;
      new DataView(b.buffer).setFloat64(1, value.value);
      chunks.push(b);
    } else if (typeof value === 'bigint') {
      if (value >= 0n) head(0, value, chunks);
      else head(1, -1n - value, chunks);
    } else if (typeof value === 'number') {
      if (Number.isInteger(value) && Number.isSafeInteger(value)) {
        if (value >= 0) head(0, value, chunks);
        else head(1, -1 - value, chunks);
      } else {
        const b = new Uint8Array(9);
        b[0] = 0xfb;
        new DataView(b.buffer).setFloat64(1, value);
        chunks.push(b);
      }
    } else if (typeof value === 'string') {
      const bytes = textEncoder.encode(value);
      head(3, bytes.length, chunks);
      chunks.push(bytes);
    } else if (value instanceof Uint8Array) {
      head(2, value.length, chunks);
      chunks.push(value);
    } else if (Array.isArray(value)) {
      head(4, value.length, chunks);
      for (const item of value) write(item, chunks);
    } else if (value instanceof Map) {
      head(5, value.size, chunks);
      for (const [k, v] of value) {
        write(k, chunks);
        write(v, chunks);
      }
    } else if (value instanceof Tagged) {
      head(6, value.tag, chunks);
      write(value.value, chunks);
    } else if (typeof value === 'object') {
      const keys = Object.keys(value);
      head(5, keys.length, chunks);
      for (const k of keys) {
        write(k, chunks);
        write(value[k], chunks);
      }
    } else {
      throw new TypeError('cannot encode ' + typeof value);
    }
  }

  // ------------------------------------------------------------------------------------------------ decoding
  function decode(bytes) {
    const reader = { view: new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), bytes, pos: 0 };
    const value = read(reader);
    if (reader.pos !== bytes.length) throw new Error('CBOR: ' + (bytes.length - reader.pos) + ' unexpected bytes after the value');
    return value;
  }

  function need(r, n) {
    if (r.pos + n > r.bytes.length) throw new Error('CBOR: unexpected end of data');
  }

  function readLength(r, info) {
    if (info < 24) return info;
    if (info === 24) { need(r, 1); return r.view.getUint8(r.pos++); }
    if (info === 25) { need(r, 2); const v = r.view.getUint16(r.pos); r.pos += 2; return v; }
    if (info === 26) { need(r, 4); const v = r.view.getUint32(r.pos); r.pos += 4; return v; }
    if (info === 27) {
      need(r, 8);
      const v = r.view.getBigUint64(r.pos);
      r.pos += 8;
      return v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v;
    }
    throw new Error('CBOR: invalid additional information ' + info);
  }

  function half(h) {
    const exponent = (h >> 10) & 0x1f;
    const fraction = h & 0x3ff;
    const sign = h & 0x8000 ? -1 : 1;
    if (exponent === 0) return sign * fraction * 2 ** -24;
    if (exponent === 31) return fraction ? NaN : sign * Infinity;
    return sign * (1 + fraction / 1024) * 2 ** (exponent - 15);
  }

  function read(r) {
    need(r, 1);
    const initial = r.view.getUint8(r.pos++);
    const major = initial >> 5;
    const info = initial & 0x1f;

    if (major === 7) {
      switch (info) {
        case 20: return false;
        case 21: return true;
        case 22: return null;
        case 23: return undefined;
        case 25: { need(r, 2); const v = half(r.view.getUint16(r.pos)); r.pos += 2; return v; }
        case 26: { need(r, 4); const v = r.view.getFloat32(r.pos); r.pos += 4; return v; }
        case 27: { need(r, 8); const v = r.view.getFloat64(r.pos); r.pos += 8; return v; }
        default: throw new Error('CBOR: unsupported simple value ' + info);
      }
    }

    if (info === 31) return readIndefinite(r, major);

    const n = readLength(r, info);
    switch (major) {
      case 0: return n;
      case 1: return typeof n === 'bigint' ? -1n - n : -1 - n;
      case 2: { need(r, n); const v = r.bytes.slice(r.pos, r.pos + n); r.pos += n; return v; }
      case 3: { need(r, n); const v = textDecoder.decode(r.bytes.subarray(r.pos, r.pos + n)); r.pos += n; return v; }
      case 4: { const a = []; for (let i = 0; i < n; i++) a.push(read(r)); return a; }
      case 5: { const m = new Map(); for (let i = 0; i < n; i++) { const k = read(r); m.set(k, read(r)); } return m; }
      case 6: return new Tagged(Number(n), read(r));
      default: throw new Error('CBOR: invalid major type');
    }
  }

  function isBreak(r) {
    need(r, 1);
    if (r.view.getUint8(r.pos) === 0xff) { r.pos++; return true; }
    return false;
  }

  function readIndefinite(r, major) {
    if (major === 4) { const a = []; while (!isBreak(r)) a.push(read(r)); return a; }
    if (major === 5) { const m = new Map(); while (!isBreak(r)) { const k = read(r); m.set(k, read(r)); } return m; }
    if (major === 2 || major === 3) {
      const parts = [];
      while (!isBreak(r)) parts.push(read(r));
      if (major === 3) return parts.join('');
      const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
      let o = 0;
      for (const p of parts) { out.set(p, o); o += p.length; }
      return out;
    }
    throw new Error('CBOR: invalid indefinite length');
  }

  // ------------------------------------------------------------------------------------------------ helpers
  /** A UUID (tag 37) from 32 hex digits (dashes allowed) or from 16 bytes */
  function uuid(source) {
    if (typeof source === 'string') {
      const hex = source.replace(/-/g, '');
      if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new Error('not a UUID: ' + source);
      return new Tagged(37, Uint8Array.from(hex.match(/../g), (h) => parseInt(h, 16)));
    }
    return new Tagged(37, source);
  }

  /** The 32 hex digits of a decoded UUID (tag 37) */
  function uuidHex(tagged) {
    if (!(tagged instanceof Tagged) || tagged.tag !== 37) throw new Error('not a UUID');
    return Array.from(tagged.value, (b) => b.toString(16).padStart(2, '0')).join('');
  }

  const Cbor = { encode, decode, Tagged, uuid, uuidHex, float: (value) => new Float(Number(value)) };
  if (typeof module !== 'undefined' && module.exports) module.exports = Cbor;
  else root.Cbor = Cbor;
})(typeof self !== 'undefined' ? self : this);
