// @api 1
// @name 捕获后返回

export default async () => {
  try {
    const hold = [];
    for (let index = 0; index < 4000000; index++) hold.push("x" + index);
  } catch (error) {
    return "没有超限";
  }
  return "没有超限";
};
