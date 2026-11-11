// @api 1
// @name 请求上限
// @connect api.example.com

export default async () => {
  await fetch("https://api.example.com/a");
  await fetch("https://api.example.com/b");
  await fetch("https://api.example.com/c");
  return "没有超限";
};
