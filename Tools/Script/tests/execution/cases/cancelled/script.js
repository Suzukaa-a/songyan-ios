// @api 1
// @name 取消
// @connect api.example.com
// @setting endpoint url 服务地址

export default async ({ settings }) => {
  const response = await fetch(settings.endpoint);
  return await response.text();
};
