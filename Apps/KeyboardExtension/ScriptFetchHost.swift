import Foundation

/// Why a fetch failed, captured by the host before the shared bridge turns it into a run error. The
/// bridge reports every transport problem as networkFailure; keeping the host's own reason lets the
/// tool surface an address, limit or timeout message instead of one generic network error.
enum ScriptHostFailure: Equatable, Sendable {
    case addressNotAllowed(host: String)
    case requestLimitExceeded
    case responseTooLarge
    case fetchTimedOut
    case networkFailure(message: String)
}

/// State shared by the C callbacks of one run. The callbacks execute on the engine thread; the
/// URLSession observer runs on its own queue, so the counters and the recorded failure are locked.
final class ScriptFetchHostContext: @unchecked Sendable {
    let allowedHosts: Set<String>
    let requestLimit: UInt32
    let responseLimit: Int
    let cancellation: ScriptRunCancellation
    /// Test seam only: production passes no classes and uses the system URL loader. A test can
    /// replace the transport with URLProtocol to exercise the real URLSession request path without a
    /// network.
    let protocolClasses: [AnyClass]

    private let lock = NSLock()
    private var requestCount: UInt32 = 0
    private var failure: ScriptHostFailure?
    private var allocations: [UnsafeMutableRawPointer] = []

    init(
        allowedHosts: Set<String>, requestLimit: UInt32, responseLimit: Int,
        cancellation: ScriptRunCancellation, protocolClasses: [AnyClass] = []
    ) {
        self.allowedHosts = allowedHosts
        self.requestLimit = requestLimit
        self.responseLimit = responseLimit
        self.cancellation = cancellation
        self.protocolClasses = protocolClasses
    }

    /// First failure wins: a transport error after a denied redirect must not hide the denial.
    func record(_ failure: ScriptHostFailure) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        lock.unlock()
    }

    var recordedFailure: ScriptHostFailure? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func nextRequestIndex() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return requestCount
    }

    /// Allocates memory whose lifetime is the run, not the callback: the shared bridge copies the
    /// response after the callback returns, so the host keeps it until the run is destroyed.
    func allocate(_ count: Int) -> UnsafeMutableRawPointer? {
        guard count > 0, let memory = malloc(count) else { return nil }
        lock.lock()
        allocations.append(memory)
        lock.unlock()
        return memory
    }

    func allocateCString(_ text: String) -> UnsafePointer<CChar>? {
        let bytes = Array(text.utf8)
        guard let memory = allocate(bytes.count + 1) else { return nil }
        let typed = memory.assumingMemoryBound(to: CChar.self)
        for (index, byte) in bytes.enumerated() {
            typed[index] = CChar(bitPattern: byte)
        }
        typed[bytes.count] = 0
        return UnsafePointer(typed)
    }

    func releaseAllocations() {
        lock.lock()
        let pending = allocations
        allocations.removeAll()
        lock.unlock()
        for memory in pending { free(memory) }
    }
}

/// Collects one URLSession response and enforces the injected size/redirect policy before the
/// shared bridge sees it. Only http(s) URLs reach it: the tool's authorize callback already refused
/// everything else.
private final class ScriptFetchObserver: NSObject, URLSessionDataDelegate {
    let semaphore = DispatchSemaphore(value: 0)
    private let context: ScriptFetchHostContext
    private let allowedHosts: Set<String>
    private let maximumBytes: Int

    private(set) var status: Int = 0
    private(set) var headers: [String: String] = [:]
    private(set) var contentType: String?
    private(set) var finalURL: URL?
    private(set) var body = Data()
    private(set) var transportError: Error?
    private(set) var isOverLimit = false
    private(set) var isDeniedRedirect = false

    init(context: ScriptFetchHostContext) {
        self.context = context
        self.allowedHosts = context.allowedHosts
        self.maximumBytes = context.responseLimit
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            finalURL = http.url
            contentType = http.value(forHTTPHeaderField: "Content-Type")
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headers[name] = text
                }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count + data.count > maximumBytes {
            isOverLimit = true
            context.record(.responseTooLarge)
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased(), allowedHosts.contains(host) else {
            isDeniedRedirect = true
            context.record(.addressNotAllowed(host: request.url?.host ?? ""))
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        transportError = error
        semaphore.signal()
    }
}

/// The bridge-facing host: authorize checks the parsed @connect hosts, fetch performs the request
/// through URLSession and enforces the injected limit shape. The callbacks are the C function
/// pointers stored in songyan_script_host; every allocation they hand to C lives until the run ends.
enum ScriptFetchHost {
    static func make(_ context: ScriptFetchHostContext) -> songyan_script_host {
        var host = songyan_script_host()
        host.userdata = Unmanaged.passUnretained(context).toOpaque()
        host.authorize = scriptHostAuthorize
        host.fetch = scriptHostFetch
        host.log = nil
        return host
    }

    /// Only declared hosts, only http(s). A redirect target is asked again by the bridge and by the
    /// URLSession delegate, so a cross-host redirect can never slip through.
    fileprivate static func authorize(_ context: ScriptFetchHostContext, url: String) -> Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = parsed.host?.lowercased()
        else {
            context.record(.addressNotAllowed(host: url))
            return false
        }
        guard context.allowedHosts.contains(host) else {
            context.record(.addressNotAllowed(host: host))
            return false
        }
        return true
    }

    fileprivate static func perform(
        context: ScriptFetchHostContext, request: songyan_script_fetch_request,
        runMillisecondsLeft: UInt32, response: inout songyan_script_fetch_response,
        errorMessage: inout UnsafePointer<CChar>?
    ) -> songyan_script_fetch_action {
        guard let urlText = request.url.map({ String(cString: $0) }),
            let url = URL(string: urlText)
        else {
            context.record(.networkFailure(message: "the request URL is not valid"))
            errorMessage = context.allocateCString("the request URL is not valid")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }
        if context.cancellation.isCancelled { return SONGYAN_SCRIPT_FETCH_REJECTED }
        let index = context.nextRequestIndex()
        guard index <= context.requestLimit else {
            context.record(.requestLimitExceeded)
            errorMessage = context.allocateCString("the script exceeded its request limit")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }
        if runMillisecondsLeft == 0 {
            context.record(.fetchTimedOut)
            errorMessage = context.allocateCString("the run's time budget is spent")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }

        var urlRequest = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Double(max(1, runMillisecondsLeft)) / 1000)
        urlRequest.httpMethod = request.method.map { String(cString: $0) } ?? "GET"
        if let body = request.body, request.body_length > 0 {
            urlRequest.httpBody = Data(bytes: body, count: request.body_length)
        }
        if let headersJSON = request.headers_json.map({ String(cString: $0) }),
            let data = headersJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            for (name, value) in parsed { urlRequest.setValue(value, forHTTPHeaderField: name) }
        }

        let observer = ScriptFetchObserver(context: context)
        let configuration = URLSessionConfiguration.ephemeral
        if !context.protocolClasses.isEmpty {
            configuration.protocolClasses = context.protocolClasses
        }
        configuration.timeoutIntervalForRequest = Double(max(1, runMillisecondsLeft)) / 1000
        configuration.timeoutIntervalForResource = Double(max(1, runMillisecondsLeft)) / 1000
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        task.resume()

        let deadline = Date().addingTimeInterval(Double(max(1, runMillisecondsLeft)) / 1000)
        while observer.semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if context.cancellation.isCancelled {
                task.cancel()
                session.invalidateAndCancel()
                return SONGYAN_SCRIPT_FETCH_REJECTED
            }
            if Date() >= deadline {
                context.record(.fetchTimedOut)
                task.cancel()
                session.invalidateAndCancel()
                errorMessage = context.allocateCString("the network request exceeded the run's time budget")
                return SONGYAN_SCRIPT_FETCH_REJECTED
            }
        }
        session.finishTasksAndInvalidate()

        if observer.isDeniedRedirect {
            errorMessage = context.allocateCString("the redirect target is not declared by @connect")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }
        if observer.isOverLimit {
            errorMessage = context.allocateCString("the response exceeds the script's size limit")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }
        if context.cancellation.isCancelled {
            errorMessage = context.allocateCString("the run was cancelled")
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }
        if let error = observer.transportError {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                context.record(.fetchTimedOut)
                errorMessage = context.allocateCString(
                    "the network request exceeded the run's time budget")
            } else {
                context.record(.networkFailure(message: error.localizedDescription))
                errorMessage = context.allocateCString(error.localizedDescription)
            }
            return SONGYAN_SCRIPT_FETCH_REJECTED
        }

        response.status = UInt32(clamping: observer.status)
        if let contentType = observer.contentType {
            response.content_type = context.allocateCString(contentType)
        }
        if let finalURL = observer.finalURL?.absoluteString {
            response.final_url = context.allocateCString(finalURL)
        }
        response.headers_json = Self.jsonHeaders(observer.headers).flatMap {
            context.allocateCString($0)
        }
        if !observer.body.isEmpty, let memory = context.allocate(observer.body.count) {
            let typed = memory.assumingMemoryBound(to: UInt8.self)
            observer.body.copyBytes(to: typed, count: observer.body.count)
            response.body = typed
            response.body_length = observer.body.count
        } else {
            response.body = nil
            response.body_length = 0
        }
        return SONGYAN_SCRIPT_FETCH_ACCEPTED
    }

    private static func jsonHeaders(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private func scriptHostAuthorize(
    _ userdata: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>?,
    _ phase: songyan_script_fetch_phase
) -> songyan_script_address_decision {
    guard let userdata, let url else { return SONGYAN_SCRIPT_ADDRESS_DENIED }
    let context = Unmanaged<ScriptFetchHostContext>.fromOpaque(userdata).takeUnretainedValue()
    let text = String(cString: url)
    return ScriptFetchHost.authorize(context, url: text)
        ? SONGYAN_SCRIPT_ADDRESS_ALLOWED : SONGYAN_SCRIPT_ADDRESS_DENIED
}

private func scriptHostFetch(
    _ userdata: UnsafeMutableRawPointer?, _ run: OpaquePointer?,
    _ request: UnsafePointer<songyan_script_fetch_request>?,
    _ response: UnsafeMutablePointer<songyan_script_fetch_response>?,
    _ errorMessage: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> songyan_script_fetch_action {
    guard let userdata, let request, let response else {
        return SONGYAN_SCRIPT_FETCH_REJECTED
    }
    let context = Unmanaged<ScriptFetchHostContext>.fromOpaque(userdata).takeUnretainedValue()
    let requestValue = request.pointee
    var responseValue = songyan_script_fetch_response()
    var message: UnsafePointer<CChar>?
    let millisecondsLeft = run.map { songyan_script_run_ms_left($0) } ?? 0
    let action = ScriptFetchHost.perform(
        context: context, request: requestValue, runMillisecondsLeft: millisecondsLeft,
        response: &responseValue, errorMessage: &message)
    if action == SONGYAN_SCRIPT_FETCH_ACCEPTED {
        response.pointee = responseValue
    } else if let message {
        errorMessage?.pointee = message
    }
    return action
}
