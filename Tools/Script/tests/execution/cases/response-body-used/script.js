// @api 1
// @name 响应复用
// @connect api.example.com

export default async () => {
  const response = await fetch("https://api.example.com/one");
  const first = await response.text();
  let second = "没有报错";
  try {
    await response.text();
  } catch (error) {
    second = error.message;
  }
  let clone = "没有报错";
  try {
    response.clone();
  } catch (error) {
    clone = error.message;
  }
  const fresh = await fetch("https://api.example.com/two");
  const copy = fresh.clone();
  const a = await fresh.text();
  const b = await copy.text();
  return [first, second, clone, a, b, String(fresh.bodyUsed)];
};
