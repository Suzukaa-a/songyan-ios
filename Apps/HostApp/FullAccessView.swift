import KeyboardCore
import SwiftUI

/// What the keyboard can do with and without "Allow Full Access", grouped the way the keyboard
/// actually behaves: iOS lets a keyboard without it read the App Group but never write it, so
/// some features work fully, some work but forget changes made inside the keyboard, and a few
/// need it outright.
struct FullAccessView: View {
    @State private var seenWithFullAccess = false

    var body: some View {
        List {
            Section {
                Label {
                    Text(
                        seenWithFullAccess
                            ? String(localized: "曾检测到已开启完全访问。若更改了系统设置，请重新确认。")
                            : String(localized: "添加键盘并开启完全访问后，在任意输入框调出一次键盘即可确认。"))
                } icon: {
                    Image(systemName: seenWithFullAccess ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(seenWithFullAccess ? Color.green : Color.secondary)
                }
                Link(String(localized: "前往设置"), destination: URL(string: UIApplication.openSettingsURLString)!)
            } footer: {
                Text("开不开启，键盘都不会连接网络，输入内容只在设备上处理。")
            }

            Section {
                row("keyboard", String(localized: "所有输入方式、键盘布局和键盘外观"))
                row("arrow.left.arrow.right", String(localized: "在键盘里切换的布局和输入方式，下次调出时保留"))
                row("text.badge.star", String(localized: "按你的用词调整候选"))
                row("curlybraces", String(localized: "不联网的脚本"))
            } header: {
                Text("不开启也能用")
            }

            Section {
                row("face.smiling", String(localized: "符号库的最近使用"))
                row("square.grid.3x3", String(localized: "九键快捷符号"))
                row("hand.draw", String(localized: "滑动输入角上的字符"))
            } header: {
                Text("能用，但在键盘里改的不会保存")
            } footer: {
                Text("在 App 里修改会照常保存。")
            }

            Section {
                row("speaker.wave.2", String(localized: "按键声音和按键触感"))
                row("text.quote", String(localized: "常用语"))
                row("network", String(localized: "联网的脚本"))
                row("arrow.triangle.2.circlepath", String(localized: "学习记录的备份与合并"))
            } header: {
                Text("需要开启")
            }
        }
        .navigationTitle(String(localized: "允许完全访问"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seenWithFullAccess = KeyboardPresenceStamp.lastFullAccessSeen() != nil }
    }

    private func row(_ systemImage: String, _ title: String) -> some View {
        Label(title, systemImage: systemImage)
    }
}
