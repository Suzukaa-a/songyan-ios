// @api 1
// @name 大响应
// @connect api.example.com

export default async () => {
  const response = await fetch("https://api.example.com/big");
  return await response.text();
};
