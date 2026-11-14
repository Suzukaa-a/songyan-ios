// @api 1
// @name 慢模型
// @connect api.example.com
// @timeout 2

export default async () => {
  const response = await fetch("https://api.example.com/v1");
  return await response.text();
};
