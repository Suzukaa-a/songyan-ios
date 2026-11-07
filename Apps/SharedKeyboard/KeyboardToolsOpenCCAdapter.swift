import Foundation
import QuickContentKit
import RimeBridge

/// The native converter owns its dictionaries and never accesses librime's global engine.
struct KeyboardToolsOpenCCAdapter: OpenCCToolConverting {
    func convert(_ text: String, using config: OpenCCToolConfig) async throws -> String {
        let name = config.rawValue
        return try await Task.detached(priority: .userInitiated) {
            // The host carries the engine tree; the extension carries just these dictionaries.
            let directory =
                Bundle.main.url(
                    forResource: "opencc", withExtension: nil, subdirectory: "EngineResources")
                ?? Bundle.main.url(forResource: "opencc", withExtension: nil)
            guard let directory else { throw OpenCCConversionError.invalidConfigURL }
            return try OpenCCConverter.convert(
                text, configURL: directory.appendingPathComponent(name + ".json"))
        }.value
    }
}
