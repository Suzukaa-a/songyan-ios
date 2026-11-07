import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// The learned words a just-installed scheme package shipped, waiting for the user's answer. They are
/// held in memory only, so leaving them unanswered drops them.
struct PackageLearningOffer: Equatable {
    let packageID: String
    let snapshots: CollectedSnapshots
    /// How many dictionaries the words belong to.
    let dictionaryCount: Int
    /// The package is the keyboard in use at its installed version, so the words merge without switching.
    let inUse: Bool
}

private enum PackageLearningFailure: Error {
    case noKeyboard
    case notInUse
}

extension SchemeImportCenter {
    /// Called after a package installed: offers its shipped learned words, if it had any.
    func offerPackageLearning(for prepared: PreparedSchemeImport) async {
        learningOffer = nil
        learningOfferNotice = nil
        let packageID = prepared.declaration.id
        guard !prepared.learningSnapshots.snapshots.isEmpty else { return }
        let inUse = await isInUse(packageID: packageID)
        learningOffer = PackageLearningOffer(
            packageID: packageID, snapshots: prepared.learningSnapshots,
            dictionaryCount: prepared.learningDictionaryCount, inUse: inUse)
    }

    /// Declining, and starting another import, drop the words.
    func declinePackageLearning() {
        guard !learningOfferBusy else { return }
        learningOffer = nil
        learningOfferNotice = nil
    }

    func dropPackageLearning(packageID: String) {
        if learningOffer?.packageID == packageID { learningOffer = nil }
    }

    /// Merges the words into the learning data of the package, after putting it in use when it is not.
    /// The merge itself runs in the keyboard, like every other learning transfer: this only submits it.
    func acceptPackageLearning() async {
        guard let offer = learningOffer, !learningOfferBusy else { return }
        learningOfferBusy = true
        learningOfferNotice = nil
        defer { learningOfferBusy = false }
        do {
            let packageID = offer.packageID
            let flow = PackageLearningMerge(
                snapshots: offer.snapshots, packageSourceID: Self.rosterKey(packageID: packageID) ?? "",
                installedRevision: { try await self.installedKeyboardIdentity(packageID: packageID).revision },
                isInUse: { await self.isInUse(packageID: packageID) },
                putInUse: { try await self.putInUse(packageID: packageID) },
                currentSource: {
                    try await LearningBackupIO.readSource().map {
                        PackageLearningSource(
                            sourceID: $0.sourceID, resourceRevision: $0.resourceRevision, sourceName: $0.sourceName)
                    }
                },
                submit: { archive in _ = try await LearningBackupIO.withStore { try $0.submitRestore(archive) } })
            try await flow.accept()
            learningOffer = nil
            learningOfferNotice = String(localized: "已安排并入。请调出「松烟」键盘一次，进度可在「学习备份」查看。")
        } catch {
            HostLog.append("package learning merge failed: \(error.localizedDescription)")
            learningOfferNotice = Self.packageLearningMessage(for: error)
        }
    }

    private static func packageLearningMessage(for error: Error) -> String {
        switch error {
        case PackageLearningFailure.noKeyboard, PackageLearningError.notInUse:
            return String(localized: "没能使用这个输入方案，用词记录没有并入。")
        case is UserKeyboardPublicationError:
            return String(localized: "没能使用这个输入方案，用词记录没有并入。")
        default:
            return LearningBackupModel.userMessage(for: error)
        }
    }

    private func isInUse(packageID: String) async -> Bool {
        guard let identity = try? await installedKeyboardIdentity(packageID: packageID),
            let shared = try? await AppliedSelectionLoader.loadActivation()
        else { return false }
        return shared.kind == .userScheme && shared.packageID == packageID && shared.recipeEnabled
            && shared.revision == identity.revision
    }

    /// The package's keyboards when it had any, otherwise its first available keyboard.
    private func putInUse(packageID: String) async throws {
        if await isInUse(packageID: packageID) { return }
        let shared = try await AppliedSelectionLoader.loadActivation()
        var keyboards = try await resolvedRosterForTargetSource(shared, packageID: packageID)
        if keyboards.isEmpty { keyboards = Array(try await addableKeyboards(packageID: packageID).prefix(1)) }
        guard !keyboards.isEmpty else { throw PackageLearningFailure.noKeyboard }
        _ = try await performReplaceKeyboards(packageID: packageID, requested: keyboards)
        selectionRevision = UUID()
    }
}

/// The question under a finished import or update: merge the learned words the package came with?
struct PackageLearningOfferSection: View {
    @ObservedObject var center: SchemeImportCenter
    /// Limits the question to one package's page; nil shows it wherever the offer is.
    var packageID: String?

    var body: some View {
        if let offer = center.learningOffer, packageID == nil || packageID == offer.packageID {
            Section {
                Text("这个方案包带有 \(offer.dictionaryCount) 份词库的用词记录，要一起并入吗？")
                Button(offer.inUse ? String(localized: "并入") : String(localized: "使用并并入")) {
                    Task { await center.acceptPackageLearning() }
                }
                .disabled(center.learningOfferBusy)
                Button(String(localized: "不并入")) { center.declinePackageLearning() }
                    .disabled(center.learningOfferBusy)
                if center.learningOfferBusy {
                    ProgressView()
                }
                if let notice = center.learningOfferNotice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if let notice = center.learningOfferNotice, packageID == nil {
            Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
