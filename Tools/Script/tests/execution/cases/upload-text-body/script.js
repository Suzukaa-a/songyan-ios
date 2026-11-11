// @api 1
// @name 文本上传
// @connect api.example.com

export default async ({ text }) => {
  const response = await fetch("https://api.example.com/echo", {
    method: "POST",
    headers: { "content-type": "application/json", "x-note": "测试" },
    body: JSON.stringify({ input: text }),
  });
  return await response.text();
};
