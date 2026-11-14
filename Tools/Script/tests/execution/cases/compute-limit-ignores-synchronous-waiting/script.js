// @api 1
// @name 等待不算计算时间
// @connect api.example.com

export default async () => {
  const response = await fetch("https://api.example.com/v1");
  return await response.text();
};
