# Songyan (松烟)

![CI](../../actions/workflows/ci.yml/badge.svg)

[简体中文](README.zh-CN.md)

Songyan is a keyboard for iPhone and iPad built on the [RIME](https://rime.im) input method engine.
It types in whatever your RIME input scheme types: pinyin and double pinyin, zhuyin, cangjie,
Cantonese, Japanese and more. The engine runs inside the keyboard on your device. It shares its engine, schemes and file formats with
[Songyan for Android](https://github.com/Suzukaa-a/songyan-android).

<p>
  <img src=".github/screenshots/keyboard-14.png" width="240" alt="14-key keyboard typing nihao">
  <img src=".github/screenshots/keyboard-9.png" width="240" alt="9-key keyboard typing zhong">
  <img src=".github/screenshots/home.png" width="240" alt="Host app home screen">
</p>

## Install

1. Download the IPA from [Releases](https://github.com/Suzukaa-a/songyan-ios/releases) and install
   it with a tool that signs it under your own Apple ID, such as AltStore or Sideloadly. Or build it
   yourself (see below). iOS 17.0 or later.
2. Add Songyan under Settings → General → Keyboard → Keyboards and turn on Allow Full Access. Full
   Access is used only to share your schemes and settings between the keyboard and the Songyan app.

## What it does

- **Full pinyin and Xiaohe double pinyin built in**, on 26, 14, 18 and 9 keys.
- **Any RIME scheme.** Add one from the recommended list (rime-ice, wanxiang, bopomofo, cangjie,
  quick, cantonese, the Japanese カギロイ) or import your own from a file or a link. Nothing is
  downloaded until you confirm. Imported schemes also get zhuyin, cangjie, Japanese romaji and kana
  boards.
- **Simplified or Traditional output** (Taiwan and Hong Kong standards too), switchable per input
  method.
- **Swipe sideways on a merged key** to type either letter, with optional double pinyin hints.
- **Layouts and appearance:** edit key layouts in the app, and make appearances in the
  [appearance editor](https://suzukaa-a.github.io/songyan-themes/). Appearance files work on both iOS and Android.
- **Optional features:** typo correction, prediction, grammar models, and backups of the
  words it learned (shared with Android).
- Interface in Simplified Chinese, Traditional Chinese and Japanese.

## Privacy

Songyan collects no personal data and sends nothing to its developers or to anyone else. The keyboard
never goes online. The app connects to the internet only when you ask it to: downloading or
updating an input scheme, or downloading a dictionary or model file. What you type and the words it
learns stay on your device.

## Known issues

- **Extra 17 pt gap above the keyboard (iOS 26 and 27).** After switching apps with the keyboard
  up, or switching to Songyan from a system keyboard with a top bar, iOS can add a blank strip above
  third-party keyboards. Switch to the Emoji keyboard and back, or reopen the app. Reported to Apple
  ([forum](https://developer.apple.com/forums/thread/843093), FB24460699, FB25094825).

## Build from source

Open `Songyan.xcodeproj`, or run `make sim-stage` to build and install on a simulator without a
developer account. Prerequisites, gates and project rules are in [CONTRIBUTING.md](CONTRIBUTING.md),
the module map in [ARCHITECTURE.md](ARCHITECTURE.md), and simulator automation in
[DEBUG.md](DEBUG.md). Report security problems as described in [SECURITY.md](SECURITY.md).

## License

Copyright © 2026 Suzukaa-a. [GPL-3.0-only](LICENSE). Third-party components and their licenses are
listed in [Resources/Legal/ThirdPartyNotices.txt](Resources/Legal/ThirdPartyNotices.txt) and
[Resources/Legal/ThirdPartyNotices-iOS.txt](Resources/Legal/ThirdPartyNotices-iOS.txt).
