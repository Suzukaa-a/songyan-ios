// @api 1
// @name 异步等待

export default async ({ text }) => {
  const first = await Promise.resolve(text);
  return await new Promise((resolve) => resolve(first + "！"));
};
