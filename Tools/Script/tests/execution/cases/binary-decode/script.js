// @api 1
// @name 二进制
// @connect api.example.com

export default async () => {
  const response = await fetch("https://api.example.com/bytes");
  const bytes = await response.arrayBuffer();
  const text = new TextDecoder().decode(bytes);
  const encoded = new TextEncoder().encode(text);
  return [text, String(bytes.byteLength), String(encoded.length)];
};
