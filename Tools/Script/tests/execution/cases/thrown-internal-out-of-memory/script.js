// @api 1
// @name 抛内部OOM

export default async () => {
  throw new InternalError("out of memory");
};
