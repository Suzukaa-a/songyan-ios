# 更新日志 · Changelog

## 未发布

### 改进

- 语言切换键按输入方案的语言显示：韩文显示「한/A」，认不出语言的显示「文/A」，不再一律显示「中/英」。

### Improved

- The language switch key follows the input scheme's language: 한/A for Korean and 文/A when the language is unknown, instead of always 中/英.

## 0.2.0 (2026-11-20)

### 新增

- 「输入选项」新增「左滑删除键选择文字」（默认关闭）：按住删除键向左滑，候选栏显示要删的文字，松手删除。
- 「我的键盘」：任何键盘布局都可以加为键盘，长按语言切换键在键盘菜单里切换；装好输入方案后可以直接选要用的键盘。
- 键盘菜单里可以切换输入方案自带的开关。
- 「字体」：导入字体，分别设置候选栏和按键的字体。
- 候选栏可以关闭「显示注释」。
- 输入方案页单独列出依赖包，并写明哪个输入方案在用它。
- 可以像桌面版 Rime 一样导入方案包。
- 「脚本」页可以一键加入内置示例。

### 改进

- 「加入键盘」只列出当前输入方案用得上的布局；缺少必需的键时写明缺哪个键。
- 每个输入方案的 Rime 配置分开保存。
- 字体里没有的生僻字，候选里显示它的编码（U+…）。
- 脚本出错时显示说明文字，不再显示原始报错。

### New

- "Swipe left on Delete to select" in Input Options (off by default): hold Delete and slide left, the candidate bar shows the text that will go, and lifting deletes it.
- My Keyboards: add any keyboard layout as a keyboard and switch from the keyboard menu (press and hold the language switch key); after installing an input scheme you can pick the keyboards to use right away.
- The keyboard menu can switch the options an input scheme provides.
- Fonts: import fonts and choose one for the candidate bar and one for the keys.
- "Show notes" can be turned off for the candidate bar.
- Input Schemes lists dependency packages separately and says which input scheme uses each one.
- Import a scheme package as you would on desktop Rime.
- Scripts can add the bundled example in one tap.

### Improved

- "Add keyboard" lists only layouts the current input scheme can use, and names any key it needs that a layout lacks.
- Each input scheme keeps its own Rime configuration.
- A rare character the font cannot draw shows its code (U+…) in the candidates.
- Script errors are explained in words instead of raw error text.
