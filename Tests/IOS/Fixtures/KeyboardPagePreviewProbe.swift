import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI
import UIKit

/// Runs in a disposable simulator app built from the real host and shared sources.
/// The runner only seeds the panel's initial page; no rendering code is replaced.
@main
struct PagePreviewProbe: App {
    var body: some Scene {
        WindowGroup {
            Text("Page preview verification").task { await PagePreviewChecks.run() }
        }
    }
}

@MainActor
enum PagePreviewChecks {
    static var didRun = false

    static func run() async {
        guard !didRun, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        didRun = true
        CandidateRenders.installDefault()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var results: [[String: Any]] = []
        do {
            var custom = KeyboardPagePresets.symbolsSystem.materialized()
            custom.id = "custom-symbols"
            custom.chrome?.bottom.removeAll { $0.action.type == .globe }
            let wideReturn = custom.chrome!.bottom[0].settingWidth(1.8)
            custom.chrome?.bottom[0] = wideReturn
            var ascii = KeyboardPagePresets.symbolsSystem
            ascii.defaultSymbolMarks = .ascii
            let cases: [(String, KeyboardPageDefinition, Bool, KeyboardPageDefinition?)] = [
                ("automatic", KeyboardPagePresets.symbolsSystem, false, nil),
                ("copied", KeyboardPagePresets.symbolsSystem.materialized(), false, nil),
                ("automatic-ascii", ascii, false, nil),
                ("copied-ascii", ascii.materialized(numericMarks: .ascii), false, nil),
                ("custom", custom, false, nil),
                ("categories", KeyboardPagePresets.symbolsCategorized, true, nil),
                ("automatic-phone", KeyboardPagePresets.symbolsSystem, true, nil),
                ("missing-marks", KeyboardPagePresets.symbolsSystem, false, KeyboardPagePresets.numericKeypad),
                (
                    "copied-categories",
                    try await KeyboardPageDraftFactory.copy(
                        KeyboardPagePresets.symbolsSystem, presentation: .categorized), true, nil
                ),
            ]
            for (name, page, phone, numeric) in cases {
                for width in [402.0, 600.0] {
                    let kind: KeyboardLayoutKind = phone ? .phone9 : .qwerty26
                    let controller = KeyboardController(layout: kind, engine: DemoEngine())
                    let main = phone ? BuiltinLayouts.phone9 : BuiltinLayouts.qwerty26
                    var composition = KeyboardComposition(mainLayoutID: main.id, symbolPageID: page.id)
                    if let numeric { composition.numericPageID = numeric.id }
                    let registry = try LayoutRegistry(
                        pages: KeyboardPagePresets.all.filter { $0.id != page.id } + [page],
                        compositions: [
                            KeyboardCompositionKey(
                                inputMethodID: controller.selectedSchemaID, layout: kind.builtinLayout
                            )
                            .rawValue: composition
                        ])
                    let panel = KeyboardPanelView(
                        controller: controller, systemKeyboardSwitch: { _, _ in }, layoutRegistry: registry,
                        selectedLayoutID: main.id, candidateAreaReserved: false)
                    let prefix = name + "-" + String(Int(width))
                    let actual = await render(
                        AnyView(panel), name: prefix + "-actual", width: width, scene: scene, directory: directory)
                    let preview = await render(
                        AnyView(
                            KeyboardPagePreviewView(
                                page: page, isPhoneLayout: phone, mainLayout: kind,
                                mainDefinition: main, numericPage: numeric)),
                        name: prefix + "-preview", width: width, scene: scene, directory: directory)
                    let inset = await render(
                        AnyView(
                            KeyboardPagePreviewView(
                                page: page, isPhoneLayout: phone, mainLayout: kind,
                                mainDefinition: main, numericPage: numeric)),
                        name: prefix + "-inset", width: width, previewWidth: width - 80,
                        scene: scene, directory: directory)
                    results.append([
                        "name": prefix, "actual": actual, "preview": preview, "inset": inset,
                        "insetScale": (width - 80) / width,
                    ])
                    if page.chrome != nil {
                        let editing = await render(
                            AnyView(
                                KeyboardPagePreviewView(
                                    page: page, isPhoneLayout: phone, mainLayout: kind,
                                    mainDefinition: main, numericPage: numeric, onSelectKey: { _ in })),
                            name: prefix + "-editing", width: width, scene: scene, directory: directory)
                        results[results.count - 1]["editing"] = editing
                    }
                }
            }
            let letters = try await letterCases(scene: scene, directory: directory)
            let data = try JSONSerialization.data(
                withJSONObject: ["cases": results, "letterCases": letters], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("page-preview-report.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["error": String(describing: error)])
                .write(to: directory.appendingPathComponent("page-preview-report.json"))
        }
    }

    private static func letterCases(scene: UIWindowScene, directory: URL) async throws -> [[String: Any]] {
        PagePreviewStart.page = .letters
        var results: [[String: Any]] = []
        for name in ["qwerty", "copied-qwerty", "english-qwerty"] {
            for compact in [false, true] {
                for width in [402.0, 600.0] {
                    let main = name == "copied-qwerty" ? BuiltinLayouts.qwerty26.copy() : BuiltinLayouts.qwerty26
                    let english = KeyboardPagePresets.englishQwerty.materialized()
                    let controller = KeyboardController(layout: .qwerty26, engine: DemoEngine())
                    if name == "english-qwerty" { controller.setInputMode(.english) }
                    let key = KeyboardCompositionKey(inputMethodID: controller.selectedSchemaID, layout: .qwerty26)
                    let registry = try LayoutRegistry(
                        layouts: BuiltinLayouts.all.filter { $0.id != main.id } + [main],
                        pages: KeyboardPagePresets.all.filter { $0.id != english.id } + [english],
                        compositions: [key.rawValue: .init(mainLayoutID: main.id, englishPageID: english.id)])
                    let panel = KeyboardPanelView(
                        controller: controller, systemKeyboardSwitch: { _, _ in }, layoutRegistry: registry,
                        selectedLayoutID: main.id, candidateAreaReserved: false)
                    let prefix = "\(name)-\(Int(width))-\(compact ? "compact" : "portrait")"
                    let actual = await render(
                        AnyView(panel), name: prefix + "-actual", width: width, scene: scene,
                        directory: directory, compact: compact)
                    var entry: [String: Any] = ["name": prefix, "actual": actual, "compact": compact]
                    for editing in [false, true] {
                        let view: AnyView
                        if name == "english-qwerty" {
                            view = AnyView(
                                KeyboardPagePreviewView(
                                    page: english, mainDefinition: main, onSelectKey: editing ? { _ in } : nil))
                        } else {
                            view = AnyView(
                                KeyboardPreviewView(
                                    layout: main, onSelectKey: editing ? { _ in } : nil))
                        }
                        let surface = editing ? "editing" : "preview"
                        entry[surface] = await render(
                            view, name: prefix + "-" + surface, width: width, scene: scene,
                            directory: directory, compact: compact)
                    }
                    results.append(entry)
                }
            }
        }
        return results
    }

    private static func render(
        _ content: AnyView, name: String, width: Double, previewWidth: Double? = nil,
        scene: UIWindowScene, directory: URL, compact: Bool = true
    ) async -> [[String: Any]] {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 360)
        let host = UIHostingController(
            rootView:
                content
                .frame(width: previewWidth ?? width)
                .frame(width: width, height: 360, alignment: .bottom)
                .environment(\.colorScheme, .light)
                .environment(\.verticalSizeClass, compact ? .compact : .regular)
                .environment(\.keyboardAppearance, KeyboardAppearance(skin: .systemDefault, dark: false))
                .ignoresSafeArea())
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        var controls: [(UIView, CGRect)] = []
        func visit(_ view: UIView) {
            guard !view.isHidden else { return }
            if view is KeyboardKeyHitTarget, !view.isHidden {
                let rect = view.convert(view.bounds, to: host.view)
                var visible = host.view.bounds.intersection(rect)
                var ancestor = view.superview
                while let parent = ancestor {
                    if parent.clipsToBounds {
                        visible = visible.intersection(parent.convert(parent.bounds, to: host.view))
                    }
                    ancestor = parent.superview
                }
                if visible.width > 1, visible.height > 1 { controls.append((view, rect)) }
            }
            for child in view.subviews { visit(child) }
        }
        visit(host.view)
        let bottom = controls.map { $0.1.maxY }.max() ?? 0
        controls = controls.filter { $0.1.minY >= bottom - 240 }
        let originY = controls.map { $0.1.minY }.min() ?? 0
        let originX = controls.map { $0.1.minX }.min() ?? 0
        let records = controls.map { view, rect -> [String: Any] in
            var text: [String] = []
            func labels(_ view: UIView) {
                if let label = view as? UILabel, let value = label.text, !value.isEmpty { text.append(value) }
                for child in view.subviews { labels(child) }
            }
            labels(view)
            return [
                "label": view.accessibilityLabel ?? "", "text": text,
                "x": rect.minX - originX, "y": rect.minY - originY,
                "width": rect.width, "height": rect.height,
            ]
        }
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
        window.isHidden = true
        window.rootViewController = nil
        return records
    }
}
