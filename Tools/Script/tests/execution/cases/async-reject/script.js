// @api 1
// @name 异步失败

export default async () => {
  await Promise.resolve();
  throw new Error("异步失败");
};
