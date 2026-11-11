// @api 1
// @name 润色
// @connect api.example.com
// @setting endpoint url 服务地址

export default async ({ text, settings }) => {
  const response = await fetch(settings.endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ input: text }),
  });
  if (!response.ok) throw new Error("服务返回 " + response.status);
  const data = await response.json();
  return data.output;
};
