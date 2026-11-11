// @api 1
// @name 抛OOM

export default async () => {
  throw new Error("out of memory");
};
