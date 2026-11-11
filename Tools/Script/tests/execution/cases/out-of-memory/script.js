// @api 1
// @name 内存

export default async () => {
  const hold = [];
  for (let index = 0; index < 4000000; index++) hold.push("x" + index);
  return "没有超限";
};
