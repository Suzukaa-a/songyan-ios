// @api 1
// @name 长地址
// @connect api.example.com

export default async () => {
  const url = "https://api.example.com/" + "a".repeat(700);
  const response = await fetch(url);
  return await response.text();
};
