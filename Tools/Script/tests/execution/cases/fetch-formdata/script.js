// @api 1
// @name 表单
// @connect api.example.com

export default async ({ text }) => {
  const form = new FormData();
  form.append("input", text);
  form.append("count", "1");
  form.append("bytes", new Uint8Array([0x00, 0xff]));
  const response = await fetch("https://api.example.com/form", { method: "POST", body: form });
  return String(response.status) + ":" + form.has("input") + ":" + form.get("count");
};
