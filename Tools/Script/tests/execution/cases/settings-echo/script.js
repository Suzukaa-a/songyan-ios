// @api 1
// @name 设置
// @setting endpoint url 服务地址
// @secret key 密钥

export default async ({ settings }) => settings.endpoint + "|" + settings.key;
