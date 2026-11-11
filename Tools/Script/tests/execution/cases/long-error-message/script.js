// @api 1
// @name 长错误

export default async () => {
  throw new Error("错".repeat(300));
};
