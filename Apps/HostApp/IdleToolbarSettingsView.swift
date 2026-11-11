import KeyboardCore
import SwiftUI
import UIKit

/// Chooses which idle-toolbar buttons show and in what order. The keyboard reads the stored layout
/// at its next presentation.
struct IdleToolbarSettingsView: View {
    @State private var layout = KeyboardIdleToolbarLayoutPreferences.read(
        from: KeyboardIdleToolbarLayoutPreferences.defaults)

    var body: some View {
        // The portrait width, so the count does not change when the device is rotated.
        GeometryReader { proxy in
            let limit = IdleToolbarCapacity.limit(
                width: Double(min(proxy.size.width, proxy.size.height)),
                fixedSlots: UIDevice.current.userInterfaceIdiom == .pad ? 1 : 0)
            List {
                Section {
                    ForEach(Array(layout.entries.enumerated()), id: \.element.item) { index, entry in
                        row(entry, overWidth: entry.shown && shownRank(of: index) >= limit)
                    }
                    .onMove { source, destination in
                        update(layout.moving(fromOffsets: source, toOffset: destination))
                    }
                } header: {
                    Text("这台设备的工具栏最多显示 \(limit) 个")
                        .textCase(nil)
                } footer: {
                    Text("关掉的按钮不会出现在工具栏上。")
                }
                Section {
                    Button(String(localized: "恢复默认")) { update(.default) }
                        .disabled(layout.isDefault)
                        .accessibilityIdentifier("idleToolbar.reset")
                }
            }
        }
        .navigationTitle(String(localized: "工具栏"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    /// How many shown entries come before `index`: the keyboard drops overflow from the end of the
    /// user's order, so an entry is past the limit when this many or more come first.
    private func shownRank(of index: Int) -> Int {
        layout.entries[..<index].filter(\.shown).count
    }

    private func row(_ entry: IdleToolbarLayout.Entry, overWidth: Bool) -> some View {
        Toggle(
            isOn: Binding(
                get: { entry.shown },
                set: { update(layout.withShown(entry.item, $0)) })
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.title)
                if overWidth {
                    Text("超出宽度，不显示")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("idleToolbar.\(entry.item.rawValue)")
    }

    private func update(_ next: IdleToolbarLayout) {
        layout = next
        KeyboardIdleToolbarLayoutPreferences.write(next, to: KeyboardIdleToolbarLayoutPreferences.defaults)
    }
}

extension IdleToolbarItem {
    fileprivate var title: String {
        switch self {
        case .emoji: String(localized: "颜文字")
        case .oneHand: String(localized: "单手模式")
        case .settings: String(localized: "键盘设置")
        }
    }
}
