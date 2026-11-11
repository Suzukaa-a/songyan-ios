// @api 1
// @name 捕获OOM

export default async () => {
  try {
    const hold = [];
    for (let index = 0; index < 4000000; index++) hold.push("x" + index);
  } catch (error) {
    throw new Error("普通错误");
  }
  return "没有超限";
};
