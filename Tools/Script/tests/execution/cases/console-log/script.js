// @api 1
// @name 日志

export default async ({ text }) => {
  console.log("第一行", text);
  console.log({ key: "值" });
  return text;
};
