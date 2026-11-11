// @api 1
// @name 孤立代理

export default async ({ text }) => {
  console.log("日志\uD800");
  return [text + "\uD800", text + "\uDC00"];
};
