// @api 1
// @name 异步大响应
// @connect api.example.com

export default async () => {
  const response = await fetch("https://api.example.com/v1");
  const text = await response.text();
  return String(text.length);
};
