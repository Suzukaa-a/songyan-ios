// @api 1
// @name 二进制上传
// @connect api.example.com

export default async () => {
  const bytes = new Uint8Array([0x00, 0x01, 0xff, 0x41]);
  const response = await fetch("https://api.example.com/raw", {
    method: "PUT",
    headers: { "content-type": "application/octet-stream" },
    body: bytes,
  });
  return String(response.status);
};
