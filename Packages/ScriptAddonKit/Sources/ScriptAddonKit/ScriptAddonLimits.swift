/// Host-injected limits for import and the in-app try-run. The contract carries no
/// numbers: every value comes from the host, and a zero value means the host has not
/// measured it yet, so nothing can run on a guess.
public struct ScriptAddonLimits: Equatable, Sendable {
    public let maximumSourceBytes: Int
    public let maximumInputTextBytes: Int
    public let sourceBytes: Int
    public let heapBytes: Int
    public let durationMilliseconds: UInt32
    public let requestCount: UInt32
    public let responseBytes: Int

    public init(
        maximumSourceBytes: Int, maximumInputTextBytes: Int, sourceBytes: Int, heapBytes: Int,
        durationMilliseconds: UInt32, requestCount: UInt32, responseBytes: Int
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumInputTextBytes = maximumInputTextBytes
        self.sourceBytes = sourceBytes
        self.heapBytes = heapBytes
        self.durationMilliseconds = durationMilliseconds
        self.requestCount = requestCount
        self.responseBytes = responseBytes
    }

    public var isRunnable: Bool {
        sourceBytes > 0 && heapBytes > 0 && durationMilliseconds > 0 && requestCount > 0
            && responseBytes > 0 && maximumSourceBytes > 0
    }
}
