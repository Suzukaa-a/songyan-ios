// The script environment, installed by the C bridge before the user's script is compiled.
//
// Only the globals the contract promises exist here: fetch, FormData, TextEncoder, TextDecoder and
// console.log. There is no DOM, no timer, no storage and no host access; the bridge supplies the
// raw fetch call and receives console lines. Nothing in this file may open a socket or decide
// whether an address is allowed: the platform host owns both through its callbacks.
//
// The whole environment lives in this closure so that the two raw bridge entry points and the
// helpers the bridge resolves cannot be reached from user code.
(function () {
"use strict";

const __rawLog = globalThis.__songyanLog;
const __rawFetch = globalThis.__songyanFetchRaw;
delete globalThis.__songyanLog;
delete globalThis.__songyanFetchRaw;

function __songyan_string(value) {
  if (typeof value === "string") {
    return value;
  }
  if (typeof value === "undefined") {
    return "undefined";
  }
  if (value === null) {
    return "null";
  }
  if (typeof value === "object" || typeof value === "function") {
    try {
      const json = JSON.stringify(value);
      if (typeof json === "string") {
        return json;
      }
    } catch (error) {
      // Cycles and BigInt throw; fall through to String().
    }
    try {
      return String(value);
    } catch (error) {
      return Object.prototype.toString.call(value);
    }
  }
  return String(value);
}

function __songyan_describe(value) {
  let message = "";
  let stack = "";
  try {
    if (value instanceof Error) {
      message = __songyan_string(value.message);
      stack = __songyan_string(value.stack || "");
    } else {
      message = __songyan_string(value);
    }
  } catch (error) {
    message = "the script threw a value that cannot be described";
  }
  return { message: message, stack: stack };
}

// console.log joins its arguments the way a browser console does and hands one line to the bridge.
// The bridge applies no size cap: the host receives every line and owns retention and display.
globalThis.console = {
  log: function () {
    const parts = [];
    for (let index = 0; index < arguments.length; index++) {
      parts.push(__songyan_string(arguments[index]));
    }
    __rawLog(parts.join(" "));
  },
};

// ---- UTF-8 ----

// Encodes one code point into bytes; used by both TextEncoder methods.
function __songyan_codepoint_bytes(code) {
  if (code < 0x80) {
    return [code];
  }
  if (code < 0x800) {
    return [0xc0 | (code >> 6), 0x80 | (code & 0x3f)];
  }
  if (code < 0x10000) {
    return [0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f)];
  }
  return [
    0xf0 | (code >> 18),
    0x80 | ((code >> 12) & 0x3f),
    0x80 | ((code >> 6) & 0x3f),
    0x80 | (code & 0x3f),
  ];
}

// Reads one scalar value from a JS string starting at index. A lone surrogate becomes U+FFFD and
// reports one code unit; a surrogate pair reports two.
function __songyan_scalar(text, index) {
  let code = text.charCodeAt(index);
  if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
    const low = text.charCodeAt(index + 1);
    if (low >= 0xdc00 && low <= 0xdfff) {
      return { code: 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00), units: 2 };
    }
  }
  if (code >= 0xd800 && code <= 0xdfff) {
    return { code: 0xfffd, units: 1 };
  }
  return { code: code, units: 1 };
}

function __songyan_utf8_encode(text) {
  const bytes = [];
  for (let index = 0; index < text.length; ) {
    const scalar = __songyan_scalar(text, index);
    const encoded = __songyan_codepoint_bytes(scalar.code);
    for (let at = 0; at < encoded.length; at++) {
      bytes.push(encoded[at]);
    }
    index += scalar.units;
  }
  return new Uint8Array(bytes);
}

function __songyan_view_of(input) {
  if (input === undefined) {
    return new Uint8Array(0);
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  if (ArrayBuffer.isView(input)) {
    return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  }
  throw new TypeError("TextDecoder.decode expects an ArrayBuffer or a typed array");
}

function __songyan_utf8_error(fatal) {
  if (fatal) {
    throw new TypeError("the encoded data was not valid UTF-8");
  }
}

// Decodes UTF-8 following the TextDecoder algorithm: maximal subparts become single replacements,
// an incomplete trailing sequence is either kept for the next chunk (stream: true) or replaced,
// and fatal mode throws instead of replacing.
function __songyan_utf8_decode(combined, fatal, stream, pending) {
  let text = "";
  let index = 0;
  while (index < combined.length) {
    const lead = combined[index];
    let need = 0;
    let secondLow = 0x80;
    let secondHigh = 0xbf;
    if (lead <= 0x7f) {
      text += String.fromCharCode(lead);
      index++;
      continue;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      need = 1;
    } else if (lead === 0xe0) {
      need = 2;
      secondLow = 0xa0;
    } else if (lead >= 0xe1 && lead <= 0xec) {
      need = 2;
    } else if (lead === 0xed) {
      need = 2;
      secondHigh = 0x9f;
    } else if (lead >= 0xee && lead <= 0xef) {
      need = 2;
    } else if (lead === 0xf0) {
      need = 3;
      secondLow = 0x90;
    } else if (lead >= 0xf1 && lead <= 0xf3) {
      need = 3;
    } else if (lead === 0xf4) {
      need = 3;
      secondHigh = 0x8f;
    } else {
      __songyan_utf8_error(fatal);
      text += "\ufffd";
      index++;
      continue;
    }
    if (index + need >= combined.length) {
      if (stream) {
        pending.bytes = combined.slice(index);
        return text;
      }
      __songyan_utf8_error(fatal);
      text += "\ufffd";
      break;
    }
    let consumed = 0;
    const second = combined[index + 1];
    if ((second & 0xc0) !== 0x80 || second < secondLow || second > secondHigh) {
      consumed = 1;
    } else {
      let code = lead & (need === 1 ? 0x1f : need === 2 ? 0x0f : 0x07);
      code = (code << 6) | (second & 0x3f);
      let ok = true;
      for (let step = 2; step <= need; step++) {
        const next = combined[index + step];
        if ((next & 0xc0) !== 0x80) {
          consumed = step;
          ok = false;
          break;
        }
        code = (code << 6) | (next & 0x3f);
      }
      if (ok) {
        index += need + 1;
        if (code < 0x10000) {
          text += String.fromCharCode(code);
        } else {
          const adjusted = code - 0x10000;
          text += String.fromCharCode(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff));
        }
        continue;
      }
    }
    __songyan_utf8_error(fatal);
    text += "\ufffd";
    index += consumed;
  }
  return text;
}

globalThis.TextEncoder = class TextEncoder {
  constructor() {
    this.encoding = "utf-8";
  }
  encode(input) {
    return __songyan_utf8_encode(input === undefined ? "" : String(input));
  }
  encodeInto(source, destination) {
    if (!(destination instanceof Uint8Array)) {
      throw new TypeError("TextEncoder.encodeInto expects a Uint8Array destination");
    }
    const text = source === undefined ? "" : String(source);
    let read = 0;
    let written = 0;
    for (let index = 0; index < text.length; ) {
      const scalar = __songyan_scalar(text, index);
      const encoded = __songyan_codepoint_bytes(scalar.code);
      if (written + encoded.length > destination.length) {
        break;
      }
      for (let at = 0; at < encoded.length; at++) {
        destination[written + at] = encoded[at];
      }
      written += encoded.length;
      read += scalar.units;
      index += scalar.units;
    }
    return { read: read, written: written };
  }
};

function __songyan_option_object(value, owner) {
  if (value === undefined || value === null) {
    return {};
  }
  if (typeof value !== "object") {
    throw new TypeError(owner + " options must be an object");
  }
  return value;
}

function __songyan_reject_unknown_options(options, allowed, owner) {
  for (const key of Object.keys(options)) {
    if (allowed.indexOf(key) < 0) {
      throw new TypeError(owner + " option " + key + " is not supported");
    }
  }
}

function __songyan_boolean(value) {
  return value === undefined ? false : Boolean(value);
}

globalThis.TextDecoder = class TextDecoder {
  constructor(label, options) {
    const name = label === undefined ? "utf-8" : String(label).toLowerCase();
    if (name !== "utf-8" && name !== "utf8" && name !== "unicode-1-1-utf-8") {
      throw new RangeError("only utf-8 is supported, not " + name);
    }
    const settings = __songyan_option_object(options, "TextDecoder");
    __songyan_reject_unknown_options(settings, ["fatal", "ignoreBOM"], "TextDecoder");
    this.encoding = "utf-8";
    this.fatal = __songyan_boolean(settings.fatal);
    this.ignoreBOM = __songyan_boolean(settings.ignoreBOM);
    this.__pending = new Uint8Array(0);
    this.__bomSeen = false;
  }
  decode(input, options) {
    const settings = __songyan_option_object(options, "TextDecoder.decode");
    __songyan_reject_unknown_options(settings, ["stream"], "TextDecoder.decode");
    const stream = __songyan_boolean(settings.stream);
    const bytes = __songyan_view_of(input);
    let combined = bytes;
    if (this.__pending.length > 0) {
      combined = new Uint8Array(this.__pending.length + bytes.length);
      combined.set(this.__pending, 0);
      combined.set(bytes, this.__pending.length);
      this.__pending = new Uint8Array(0);
    }
    if (!stream && combined.length === 0) {
      this.__bomSeen = false;
      return "";
    }
    const state = { bytes: null };
    let text = __songyan_utf8_decode(combined, this.fatal, stream, state);
    if (state.bytes !== null) {
      this.__pending = state.bytes;
    }
    if (!this.ignoreBOM && !this.__bomSeen && text.length > 0) {
      if (text.charCodeAt(0) === 0xfeff) {
        text = text.slice(1);
      }
      this.__bomSeen = true;
    }
    if (!stream) {
      this.__bomSeen = false;
    }
    return text;
  }
};

// ---- FormData ----

let __songyan_boundary_counter = 0;

function __songyan_bytes_of(value) {
  if (typeof value === "string") {
    return __songyan_utf8_encode(value);
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  return null;
}

// A fixed-length boundary keeps the encoded request size stable for the shared cases; the value
// is still random because user content could otherwise contain it.
function __songyan_boundary() {
  let random = "";
  for (let index = 0; index < 4; index++) {
    random += Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
  }
  __songyan_boundary_counter++;
  return "----songyanform" + random + __songyan_boundary_counter.toString(16);
}

function __songyan_multipart(entries) {
  const boundary = __songyan_boundary();
  const pieces = [];
  for (const entry of entries) {
    const name = String(entry[0])
      .replace(/\r/g, "%0D")
      .replace(/\n/g, "%0A")
      .replace(/"/g, "%22");
    pieces.push(
      __songyan_utf8_encode(
        "--" + boundary + "\r\n" +
          'Content-Disposition: form-data; name="' + name + '"\r\n\r\n'
      )
    );
    const value = entry[1];
    const bytes = value && typeof value === "object" && value.__songyanBlob === true
      ? __songyan_bytes_of(value.bytes)
      : __songyan_bytes_of(value);
    if (bytes === null) {
      throw new TypeError("FormData values must be strings, ArrayBuffers or typed arrays");
    }
    pieces.push(bytes);
    pieces.push(__songyan_utf8_encode("\r\n"));
  }
  pieces.push(__songyan_utf8_encode("--" + boundary + "--\r\n"));
  let total = 0;
  for (const piece of pieces) {
    total += piece.length;
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const piece of pieces) {
    joined.set(piece, offset);
    offset += piece.length;
  }
  return { contentType: "multipart/form-data; boundary=" + boundary, bytes: joined.buffer };
}

globalThis.FormData = class FormData {
  constructor() {
    this.__entries = [];
  }
  append(name, value) {
    this.__entries.push([String(name), value]);
  }
  set(name, value) {
    const key = String(name);
    this.delete(key);
    this.__entries.push([key, value]);
  }
  has(name) {
    const key = String(name);
    return this.__entries.some((entry) => entry[0] === key);
  }
  get(name) {
    const key = String(name);
    const entry = this.__entries.find((item) => item[0] === key);
    return entry === undefined ? null : entry[1];
  }
  getAll(name) {
    const key = String(name);
    return this.__entries.filter((entry) => entry[0] === key).map((entry) => entry[1]);
  }
  delete(name) {
    const key = String(name);
    this.__entries = this.__entries.filter((entry) => entry[0] !== key);
  }
  forEach(callback, thisArg) {
    for (const entry of this.__entries) {
      callback.call(thisArg, entry[1], entry[0], this);
    }
  }
  entries() {
    return this.__entries.map((entry) => [entry[0], entry[1]])[Symbol.iterator]();
  }
  keys() {
    return this.__entries.map((entry) => entry[0])[Symbol.iterator]();
  }
  values() {
    return this.__entries.map((entry) => entry[1])[Symbol.iterator]();
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  __encode() {
    return __songyan_multipart(this.__entries);
  }
};

// ---- Response ----

class __SongyanHeaders {
  constructor(json) {
    this.__map = {};
    if (typeof json === "string" && json.length > 0) {
      const parsed = JSON.parse(json);
      for (const key of Object.keys(parsed)) {
        this.__map[String(key).toLowerCase()] = String(parsed[key]);
      }
    }
  }
  get(name) {
    const key = String(name).toLowerCase();
    return Object.prototype.hasOwnProperty.call(this.__map, key) ? this.__map[key] : null;
  }
  has(name) {
    return Object.prototype.hasOwnProperty.call(this.__map, String(name).toLowerCase());
  }
  forEach(callback, thisArg) {
    for (const key of Object.keys(this.__map)) {
      callback.call(thisArg, this.__map[key], key, this);
    }
  }
  entries() {
    return Object.keys(this.__map)
      .map((key) => [key, this.__map[key]])
      [Symbol.iterator]();
  }
  keys() {
    return Object.keys(this.__map)[Symbol.iterator]();
  }
  values() {
    return Object.keys(this.__map)
      .map((key) => this.__map[key])
      [Symbol.iterator]();
  }
  [Symbol.iterator]() {
    return this.entries();
  }
}

class __SongyanResponse {
  constructor(status, headersJson, bytes) {
    this.status = status;
    this.ok = status >= 200 && status < 300;
    this.statusText = "";
    this.headers = new __SongyanHeaders(headersJson);
    this.__bytes = bytes === null || bytes === undefined ? new ArrayBuffer(0) : bytes;
    this.__used = false;
  }
  get bodyUsed() {
    return this.__used;
  }
  __consume() {
    if (this.__used) {
      throw new TypeError("the response body has already been used");
    }
    this.__used = true;
    return this.__bytes;
  }
  async text() {
    return new TextDecoder().decode(this.__consume());
  }
  async json() {
    return JSON.parse(await this.text());
  }
  async arrayBuffer() {
    const bytes = this.__consume();
    return bytes.slice(0);
  }
  clone() {
    if (this.__used) {
      throw new TypeError("the response body has already been used");
    }
    return new __SongyanResponse(this.status, JSON.stringify(this.headers.__map), this.__bytes);
  }
}

function __songyan_response(status, headersJson, bytes) {
  return new __SongyanResponse(status, headersJson, bytes);
}

// ---- fetch ----

const __songyan_fetch_options = ["method", "headers", "body"];
const __songyan_method_pattern = /^[A-Za-z0-9!#$%&'*+.^_\u0060|~-]+$/;

globalThis.fetch = function fetch(input, init) {
  if (typeof input !== "string") {
    throw new TypeError("fetch expects a URL string");
  }
  const options = __songyan_option_object(init, "fetch");
  __songyan_reject_unknown_options(options, __songyan_fetch_options, "fetch");
  const method = String(options.method === undefined ? "GET" : options.method).toUpperCase();
  if (!__songyan_method_pattern.test(method)) {
    throw new TypeError("fetch method is not a valid HTTP method: " + method);
  }
  const headers = {};
  const setHeader = function (name, value) {
    headers[String(name).toLowerCase()] = String(value);
  };
  if (options.headers !== undefined && options.headers !== null) {
    const source = options.headers;
    if (Array.isArray(source)) {
      for (const pair of source) {
        setHeader(pair[0], pair[1]);
      }
    } else if (typeof source.forEach === "function") {
      source.forEach(function (value, name) {
        setHeader(name, value);
      });
    } else if (typeof source === "object") {
      for (const name of Object.keys(source)) {
        setHeader(name, source[name]);
      }
    } else {
      throw new TypeError("fetch headers must be an object, an array of pairs or a Headers-like");
    }
  }
  let bodyText = null;
  let bodyBytes = null;
  const body = options.body;
  if (body !== undefined && body !== null) {
    if (method === "GET" || method === "HEAD") {
      throw new TypeError("fetch cannot send a body with " + method);
    }
    if (typeof body === "string") {
      bodyText = body;
      if (headers["content-type"] === undefined) {
        headers["content-type"] = "text/plain;charset=UTF-8";
      }
    } else if (body instanceof FormData) {
      const encoded = body.__encode();
      bodyBytes = encoded.bytes;
      if (headers["content-type"] === undefined) {
        headers["content-type"] = encoded.contentType;
      }
    } else if (body instanceof ArrayBuffer) {
      bodyBytes = body;
    } else if (ArrayBuffer.isView(body)) {
      bodyBytes = body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
    } else {
      throw new TypeError(
        "fetch body must be a string, ArrayBuffer, typed array or FormData"
      );
    }
  }
  let headersJson = null;
  if (Object.keys(headers).length > 0) {
    headersJson = JSON.stringify(headers);
  }
  return __rawFetch(input, method, headersJson, bodyText, bodyBytes);
};

return { describe: __songyan_describe, response: __songyan_response };
})();
