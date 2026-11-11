// @api 1
// @name 泄漏乙

export default async () => typeof globalThis.leak;
