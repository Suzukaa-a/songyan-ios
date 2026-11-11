// @api 1
// @name 顶层等待

const suffix = await Promise.resolve("顶层");

export default async ({ text }) => text + suffix;
