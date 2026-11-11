// @api 1
// @name 解码

export default async () => {
  const results = [];
  const withBom = new Uint8Array([0xef, 0xbb, 0xbf, 0x41]);
  results.push(new TextDecoder().decode(withBom));
  results.push(new TextDecoder("utf-8", { ignoreBOM: true }).decode(withBom));
  results.push(new TextDecoder().decode(new Uint8Array([0xe4, 0xb8])));
  results.push(new TextDecoder().decode(new Uint8Array([0xe0, 0x80, 0x80])));
  results.push(new TextDecoder().decode(new Uint8Array([0xed, 0xa0, 0x80])));
  results.push(new TextDecoder().decode(new Uint8Array([0xff])));
  let fatal = "没有报错";
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0xe4, 0xb8]));
  } catch (error) {
    fatal = error.name;
  }
  results.push(fatal);
  const streaming = new TextDecoder();
  const first = streaming.decode(new Uint8Array([0xe4]), { stream: true });
  const second = streaming.decode(new Uint8Array([0xb8, 0x80]));
  results.push(JSON.stringify(first));
  results.push(second);
  const flush = new TextDecoder();
  flush.decode(new Uint8Array([0xe4]), { stream: true });
  results.push(flush.decode());
  let unknown = "没有报错";
  try {
    new TextDecoder("utf-8", { foo: true });
  } catch (error) {
    unknown = error.message;
  }
  results.push(unknown);
  let label = "没有报错";
  try {
    new TextDecoder("utf-16");
  } catch (error) {
    label = error.name;
  }
  results.push(label);
  return results;
};
