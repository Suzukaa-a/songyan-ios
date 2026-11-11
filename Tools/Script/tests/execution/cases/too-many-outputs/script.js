// @api 1
// @name 太多结果

export default async () => {
  const items = [];
  for (let index = 0; index < 300; index++) items.push("第" + index + "条");
  return items;
};
