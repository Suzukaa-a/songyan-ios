// @api 1
// @name 全局

export default async () => {
  const names = ["fetch", "FormData", "TextEncoder", "TextDecoder"];
  const result = names.map((name) => name + "=" + typeof globalThis[name]);
  result.push("console.log=" + typeof globalThis.console.log);
  result.push("rawFetch=" + typeof globalThis.__songyanFetchRaw);
  result.push("rawLog=" + typeof globalThis.__songyanLog);
  result.push("describe=" + typeof __songyanDescribe);
  return result.join(",");
};
