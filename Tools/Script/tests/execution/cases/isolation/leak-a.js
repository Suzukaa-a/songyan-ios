// @api 1
// @name 泄漏甲

export default async () => {
  globalThis.leak = "a";
  return "a";
};
