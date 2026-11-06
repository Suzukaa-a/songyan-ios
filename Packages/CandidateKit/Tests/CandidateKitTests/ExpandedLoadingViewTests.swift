#if canImport(AppKit)
    import AppKit
    import SwiftUI
    import XCTest
    import KeyboardCore
    @testable import CandidateKit

    @available(macOS 14.0, *)
    final class ExpandedLoadingViewTests: XCTestCase {
        @MainActor
        func testCollapsedFullViewportDoesNotRequestOffscreenPages() async throws {
            for (text, pageCount) in [("春", 3), ("候选内容", 3), ("春", 9), ("候选内容", 9)] {
                let page = (0..<5).map { Candidate(index: $0, text: text) }
                let state = CandidatePresentationState(
                    schemaID: "test", rawInput: "chun", candidates: page,
                    pageSize: 5, canPageForward: true, isComposing: true)
                var browser = CandidateBrowser()
                browser.reset(state)
                for pageIndex in 1..<pageCount {
                    browser.append(pageIndex: pageIndex, candidates: page, pageSize: 5)
                }
                var reads = 0
                let context = CandidateAreaContext(
                    state: state, bar: .systemDefault,
                    actions: CandidateAreaActionSink { action in
                        if action == .loadMore { reads += 1 }
                    }, typography: .init(candidateSize: 20, secondarySize: 10), browser: browser)
                let host = NSHostingView(rootView: DefaultCandidateAreaRenderer().collapsedView(context: context))
                host.frame = NSRect(x: 0, y: 0, width: 402, height: 48)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 300_000_000)
                XCTAssertEqual(reads, 0, "A full idle strip must not request offscreen pages")
                print("COLLAPSED_IDLE_READS=\(reads)")
                let scroll = try XCTUnwrap(scrollView(in: host))
                let document = try XCTUnwrap(scroll.documentView)
                let end = max(0, document.frame.width - scroll.contentView.bounds.width)
                XCTAssertGreaterThan(end, 0)
                if pageCount == 9 {
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.width / 4, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    XCTAssertEqual(reads, 0, "A small scroll with plenty of loaded candidates must not read ahead")
                }
                // Advance through the lazy content as a native drag does; its initial extent is an estimate.
                for _ in 0..<30 {
                    if reads > 0 { break }
                    let tail = max(0, document.frame.width - scroll.contentView.bounds.width)
                    let next = min(tail, scroll.contentView.bounds.minX + scroll.contentView.bounds.width / 2)
                    scroll.contentView.scroll(to: NSPoint(x: next, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertGreaterThan(reads, 0, "Browsing must still prefetch the next pages")
                let layout = CandidateCollapsedFlow.layout(
                    entries: context.displayEntries, collapsed: context.bar.collapsed,
                    typography: context.typography, availableWidth: 402)
                let loadedWidth =
                    layout.cellWidths.reduce(0, +)
                    + CGFloat(context.displayEntries.count - 1) * CGFloat(context.bar.collapsed.cellSpacing) + 4
                XCTAssertLessThan(
                    scroll.contentView.bounds.maxX, loadedWidth,
                    "Browsing must request pages before reaching the loaded end")
                if pageCount == 9 {
                    XCTAssertGreaterThan(
                        loadedWidth - scroll.contentView.bounds.maxX, scroll.contentView.bounds.width * 2,
                        "Long lists must retain prefetch headroom instead of waiting for the tail")
                }
            }
        }

        @MainActor
        func testCollapsedViewportLoadsVisibleAndEarlierPages() async {
            for (width, pageIndex, pageSize) in [(1024.0, 0, 15), (402.0, 2, 15), (402.0, 0, 5)] {
                let state = CandidatePresentationState(
                    schemaID: "test", rawInput: "chun",
                    candidates: (0..<pageSize).map { Candidate(index: $0, text: "春") },
                    pageIndex: pageIndex, pageSize: pageSize, canPageForward: true, isComposing: true)
                var browser = CandidateBrowser()
                browser.reset(state)
                var reads = 0
                let context = CandidateAreaContext(
                    state: state, bar: .systemDefault,
                    actions: CandidateAreaActionSink { action in
                        if action == .loadMore { reads += 1 }
                    }, typography: .init(candidateSize: 20, secondarySize: 10), browser: browser)
                let host = NSHostingView(rootView: DefaultCandidateAreaRenderer().collapsedView(context: context))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 48)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                for _ in 0..<10 {
                    if reads > 0 { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                XCTAssertGreaterThan(reads, 0, "Visible tails and missing earlier pages must still load")
            }
        }

        @MainActor
        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews {
                if let scroll = scrollView(in: child) { return scroll }
            }
            return nil
        }

        @MainActor
        func testShortExpandedViewportRequestsReadWithoutScrolling() async {
            let state = CandidatePresentationState(
                schemaID: "test", rawInput: "chun",
                candidates: (0..<15).map { Candidate(index: $0, text: "春") },
                pageSize: 15, canPageForward: true, isComposing: true)
            var browser = CandidateBrowser()
            browser.reset(state)
            var reads = 0
            let context = CandidateAreaContext(
                state: state, bar: .systemDefault,
                actions: CandidateAreaActionSink { action in
                    XCTAssertEqual(action, .loadMore)
                    reads += 1
                }, typography: .init(candidateSize: 20, secondarySize: 10), browser: browser, isExpanded: true)
            let host = NSHostingView(rootView: DefaultCandidateAreaRenderer().expandedView(context: context))
            host.frame = NSRect(x: 0, y: 0, width: 402, height: 162)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // A real SwiftUI lifecycle, no scroll gesture and no call to a model-only helper.
            for _ in 0..<10 {
                if reads >= 3 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // The viewport's initial task, the prefetch row (the first row of a list
            // shorter than the prefetch distance) and the visible footer all mount.
            // The sink deliberately leaves state unchanged so each identity fires once;
            // the controller drops repeats of a read already in flight.
            XCTAssertEqual(reads, 3)
            print("EXPANDED_SHORT_VIEWPORT_INITIAL_AND_FOOTER_READS=\(reads)")
            window.contentView = nil
        }
    }
#endif
