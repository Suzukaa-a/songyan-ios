import ScriptAddonKit
import SwiftUI
import UIKit

/// The "scripts" screen: the addon list plus the four ways to add one. A script is an
/// addon like any other tool; this screen never implements a second run/preview model,
/// the keyboard's Tool panel does that from the same stored files.
struct ScriptAddonCenterView: View {
    @ObservedObject var center: ScriptAddonCenter
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var showsLink = false
    @State private var linkText = ""
    @State private var importer = false
    @State private var editorTarget: EditorTarget?
    @State private var settingsTarget: ScriptAddonStore.Addon?
    @State private var pendingDeletes: [ScriptAddonStore.Addon] = []
    @State private var showGuide = false

    var body: some View {
        List {
            if let notice = center.notice {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(notice).font(.footnote)
                        Spacer(minLength: 0)
                        Button(String(localized: "\u{597D}")) { center.clearNotice() }
                            .font(.footnote)
                    }
                }
            }
            if center.addons.isEmpty {
                emptyRow
            } else {
                ForEach(center.addons, id: \.state.id) { addon in
                    row(addon)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletes = [addon]
                            } label: {
                                Label(String(localized: "\u{5220}\u{9664}"), systemImage: "trash")
                            }
                        }
                }
                .onMove(perform: center.reorder)
                .onDelete { indexSet in
                    pendingDeletes = indexSet.compactMap { index in
                        center.addons.indices.contains(index) ? center.addons[index] : nil
                    }
                }
            }
        }
        .navigationTitle(Text(String(localized: "\u{811A}\u{672C}")))
        .toolbar {
            if !center.addons.isEmpty {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "\u{7C98}\u{8D34}\u{811A}\u{672C}\u{6587}\u{5B57}")) { showsPaste = true }
                    Button(String(localized: "\u{5BFC}\u{5165} .js \u{6587}\u{4EF6}")) { importer = true }
                    Button(String(localized: "\u{4ECE}\u{94FE}\u{63A5}\u{6DFB}\u{52A0}")) { showsLink = true }
                    Button(String(localized: "\u{65B0}\u{5EFA}\u{5E76}\u{7F16}\u{8F91}")) {
                        editorTarget = EditorTarget(addon: nil)
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showsPaste) { pasteSheet }
        .sheet(isPresented: $showsLink) { linkSheet }
        .sheet(isPresented: $showGuide) { guideSheet }
        .sheet(item: $settingsTarget) { addon in
            ScriptAddonSettingsView(center: center, addon: addon)
        }
        .sheet(item: $editorTarget) { target in
            ScriptAddonEditorView(center: center, addon: target.addon)
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.javaScript]) { result in
            if case .success(let url) = result { center.importFile(url) }
        }
        .sheet(
            item: Binding(
                get: { center.pending.map { PendingBox(draft: $0) } },
                set: { if $0 == nil { center.cancelPending() } }
            )
        ) { box in
            ScriptAddonConfirmationView(center: center, draft: box.draft)
        }
        .alert(
            center.errorMessage ?? "",
            isPresented: Binding(
                get: { center.errorMessage != nil },
                set: { if !$0 { center.errorMessage = nil } })
        ) {
            Button(String(localized: "\u{597D}")) { center.errorMessage = nil }
        }
        .confirmationDialog(
            String(localized: "\u{5220}\u{9664}\u{811A}\u{672C}\u{FF1F}"),
            isPresented: Binding(
                get: { !pendingDeletes.isEmpty },
                set: { if !$0 { pendingDeletes = [] } })
        ) {
            Button(String(localized: "\u{5220}\u{9664}"), role: .destructive) {
                for addon in pendingDeletes { center.delete(addon: addon) }
                pendingDeletes = []
            }
            Button(String(localized: "\u{53D6}\u{6D88}"), role: .cancel) { pendingDeletes = [] }
        } message: {
            Text(pendingDeletes.map { title(of: $0) }.joined(separator: "\u{3001}"))
        }
    }

    private var emptyRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "\u{8FD8}\u{6CA1}\u{6709}\u{811A}\u{672C}"))
                    .font(.headline)
                Text(
                    String(
                        localized:
                            "\u{811A}\u{672C}\u{662F}\u{4E00}\u{79CD}\u{5DE5}\u{5177}\u{FF1A}\u{5B83}\u{8BFB}\u{53D6}\u{4F60}\u{9009}\u{4E2D}\u{7684}\u{6587}\u{5B57}\u{FF08}\u{6216}\u{5149}\u{6807}\u{524D}\u{7684}\u{4E00}\u{6BB5}\u{FF09}\u{FF0C}\u{8FD4}\u{56DE}\u{6587}\u{5B57}\u{FF0C}\u{952E}\u{76D8}\u{5148}\u{9884}\u{89C8}\u{518D}\u{7531}\u{4F60}\u{51B3}\u{5B9A}\u{66FF}\u{6362}\u{3001}\u{63D2}\u{5165}\u{6216}\u{590D}\u{5236}\u{3002}"
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Button(String(localized: "\u{590D}\u{5236}\u{7ED9} AI \u{7684}\u{8BF4}\u{660E}")) {
                    UIPasteboard.general.string = ScriptAddonCenter.aiGuide()
                }
                Button(
                    String(
                        localized: "\u{67E5}\u{770B}\u{4E0D}\u{8054}\u{7F51}\u{7684}\u{6700}\u{5C0F}\u{793A}\u{4F8B}")
                ) {
                    showGuide = true
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ addon: ScriptAddonStore.Addon) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: addon))
                if center.needsReconfirmation(addon) {
                    Text(
                        String(
                            localized:
                                "\u{58F0}\u{660E}\u{5DF2}\u{53D8}\u{5316}\u{FF0C}\u{9700}\u{8981}\u{91CD}\u{65B0}\u{786E}\u{8BA4}"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if let summary = summary(of: addon) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let note = center.availabilityNote(addon) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { addon.state.enabled },
                    set: { center.setEnabled($0, addon: addon) })
            )
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { settingsTarget = addon }
        .contextMenu {
            Button(String(localized: "\u{7F16}\u{8F91}")) { editorTarget = EditorTarget(addon: addon) }
            Button(String(localized: "\u{8BBE}\u{7F6E}\u{4E0E}\u{5BC6}\u{94A5}")) { settingsTarget = addon }
            Button(String(localized: "\u{68C0}\u{67E5}\u{66F4}\u{65B0}")) { center.checkForUpdate(addon: addon) }
            if let data = center.exportData(addon: addon) {
                ShareLink(item: scriptFile(data, title: title(of: addon)))
            }
            Button(String(localized: "\u{5220}\u{9664}"), role: .destructive) { center.delete(addon: addon) }
        }
    }

    private func title(of addon: ScriptAddonStore.Addon) -> String {
        (try? center.declarations(for: addon.state.id).name) ?? addon.state.id
    }

    private func summary(of addon: ScriptAddonStore.Addon) -> String? {
        (try? center.declarations(for: addon.state.id).summary) ?? nil
    }

    private func scriptFile(_ data: Data, title: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(title).appendingPathExtension("js")
        try? data.write(to: url)
        return url
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if let error = center.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
            }
            .padding()
            .onAppear { center.errorMessage = nil }
            .navigationTitle(Text(String(localized: "\u{7C98}\u{8D34}\u{811A}\u{672C}")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{53D6}\u{6D88}")) { showsPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "\u{7EE7}\u{7EED}")) {
                        if center.stage(source: Data(pasteText.utf8)) { showsPaste = false }
                    }
                }
            }
        }
    }

    private var linkSheet: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "\u{811A}\u{672C}\u{94FE}\u{63A5}\u{FF08}https\u{FF09}"), text: $linkText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if let error = center.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .onAppear { center.errorMessage = nil }
            .navigationTitle(Text(String(localized: "\u{4ECE}\u{94FE}\u{63A5}\u{6DFB}\u{52A0}")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{53D6}\u{6D88}")) { showsLink = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "\u{4E0B}\u{8F7D}")) {
                        guard let url = URL(string: linkText),
                            url.scheme?.lowercased() == "https"
                        else {
                            center.errorMessage = String(
                                localized: "\u{8BF7}\u{8F93}\u{5165} https \u{94FE}\u{63A5}")
                            return
                        }
                        center.importLink(url)
                        showsLink = false
                    }
                }
            }
        }
    }

    private var guideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        String(
                            localized:
                                "\u{628A}\u{8FD9}\u{4E2A}\u{8BF4}\u{660E}\u{590D}\u{5236}\u{7ED9} AI\u{FF0C}\u{8BA9}\u{5B83}\u{751F}\u{6210}\u{4E00}\u{4E2A}\u{811A}\u{672C}"
                        )
                    )
                    .font(.headline)
                    Text(ScriptAddonCenter.aiGuide())
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Divider()
                    Text(String(localized: "\u{4E0D}\u{8054}\u{7F51}\u{7684}\u{6700}\u{5C0F}\u{793A}\u{4F8B}"))
                        .font(.headline)
                    Text(ScriptAddonCenter.minimalExample())
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
            }
            .navigationTitle(Text(String(localized: "\u{7ED9} AI \u{7684}\u{8BF4}\u{660E}")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{5B8C}\u{6210}")) { showGuide = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "\u{590D}\u{5236}\u{8BF4}\u{660E}")) {
                        UIPasteboard.general.string = ScriptAddonCenter.aiGuide()
                    }
                }
            }
        }
    }
}

/// Wraps a draft so it can drive a sheet's item binding.
struct PendingBox: Identifiable {
    let draft: ScriptAddonCenter.Draft
    var id: String { draft.id }
}
