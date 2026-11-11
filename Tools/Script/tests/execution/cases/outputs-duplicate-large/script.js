// @api 1
// @name 重复引用

export default async () => {
  const big = "x".repeat(3000000);
  return [big, big, big, big];
};
