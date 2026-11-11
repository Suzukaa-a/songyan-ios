// @api 1
// @name 选项

export default async () => {
  const messages = [];
  const options = [{ signal: 1 }, { mode: "cors" }, { credentials: "include" }];
  for (const option of options) {
    try {
      fetch("https://api.example.com/x", option);
      messages.push("没有报错");
    } catch (error) {
      messages.push(error.message);
    }
  }
  try {
    fetch({});
  } catch (error) {
    messages.push(error.message);
  }
  try {
    fetch("https://api.example.com/x", { method: "GE T" });
  } catch (error) {
    messages.push(error.message);
  }
  try {
    fetch("https://api.example.com/x", { method: "GET", body: "x" });
  } catch (error) {
    messages.push(error.message);
  }
  return messages;
};
