// @api 1
// @name 并发请求
// @connect api.example.com

export default async () => {
  const pair = await Promise.all([
    fetch("https://api.example.com/a").then((response) => response.text()),
    fetch("https://api.example.com/b").then((response) => response.text()),
  ]);
  return pair[0] + "|" + pair[1];
};
