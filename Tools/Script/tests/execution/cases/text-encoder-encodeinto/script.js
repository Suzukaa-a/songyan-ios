// @api 1
// @name 编码

export default async () => {
  const encoder = new TextEncoder();
  const destination = new Uint8Array(4);
  const first = encoder.encodeInto("a😀", destination);
  const pair = encoder.encodeInto("😀", new Uint8Array(3));
  const all = encoder.encodeInto("ab", new Uint8Array(8));
  let typeError = "没有报错";
  try {
    encoder.encodeInto("x", new ArrayBuffer(2));
  } catch (error) {
    typeError = error.name;
  }
  return [
    JSON.stringify(first),
    JSON.stringify(pair),
    JSON.stringify(all),
    Array.from(destination).join(","),
    typeError,
  ];
};
