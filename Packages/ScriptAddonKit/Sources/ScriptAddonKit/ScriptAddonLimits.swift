/// Limits for import and the in-app try-run, filled by the app from the shared contract's
/// shipped values. A zero value means the host has not set it, so nothing runs.
public struct ScriptAddonLimits: Equatable, Sendable {
    public let maximumSourceBytes: Int
    public let maximumInputTextBytes: Int
    public let sourceBytes: Int
    public let heapBytes: Int
    public let durationMilliseconds: UInt32
    public let computeMilliseconds: UInt32
    public let requestCount: UInt32
    public let responseBytes: Int

    public init(
        maximumSourceBytes: Int, maximumInputTextBytes: Int, sourceBytes: Int, heapBytes: Int,
        durationMilliseconds: UInt32, computeMilliseconds: UInt32, requestCount: UInt32,
        responseBytes: Int
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumInputTextBytes = maximumInputTextBytes
        self.sourceBytes = sourceBytes
        self.heapBytes = heapBytes
        self.durationMilliseconds = durationMilliseconds
        self.computeMilliseconds = computeMilliseconds
        self.requestCount = requestCount
        self.responseBytes = responseBytes
    }

    public var isRunnable: Bool {
        sourceBytes > 0 && heapBytes > 0 && durationMilliseconds > 0 && computeMilliseconds > 0
            && requestCount > 0
            && responseBytes > 0 && maximumSourceBytes > 0
    }
}
