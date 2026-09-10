import BrowserCaptureKit
import Foundation

/// Host-level evidence item. Package capture events are wrapped so lifecycle
/// and dialog evidence share one ordered stream.
enum HostEvent: Equatable {
    case capture(BrowserCaptureEvent)
    case dialog(kind: String, message: String?)
    case lifecycle(String)
}

struct StoredEvent: Equatable {
    let sequence: Int
    let capturedAt: Date
    let pageEpoch: Int
    let event: HostEvent
}

/// Assigns sequence numbers at record time, bounds memory, and builds the
/// sanitized export page. Raw package events stay in memory on the phone;
/// only ``ExportedEvent`` values leave.
@MainActor
final class EvidenceCollector {
    let capacity: Int
    private(set) var latestSequence = 0
    /// Highest sequence discarded from the buffer; `nil` until the first drop.
    private(set) var droppedThrough: Int?
    private var buffer: [StoredEvent] = []

    init(capacity: Int = 1_000) {
        self.capacity = max(1, capacity)
    }

    /// Accessibility and browser-state events are never buffered: observations
    /// travel through `observe`, and browser state holds cookies and storage.
    func record(_ event: HostEvent, pageEpoch: Int, capturedAt: Date = Date()) {
        if case .capture(let capture) = event {
            switch capture {
            case .accessibility, .browserState:
                return
            default:
                break
            }
        }
        latestSequence += 1
        buffer.append(StoredEvent(sequence: latestSequence, capturedAt: capturedAt, pageEpoch: pageEpoch, event: event))
        if buffer.count > capacity {
            let overflow = buffer.count - capacity
            droppedThrough = buffer[overflow - 1].sequence
            buffer.removeFirst(overflow)
        }
    }

    func page(after cursor: Int, limit: Int) -> EventPage {
        let matching = buffer.filter { $0.sequence > cursor }
        let slice = Array(matching.prefix(limit))
        let exported = slice.map(Self.export)
        return EventPage(
            events: exported,
            fromSequence: slice.first?.sequence ?? cursor + 1,
            toSequence: slice.last?.sequence ?? cursor,
            latestSequence: latestSequence,
            droppedThrough: droppedThrough.map { $0 > cursor ? $0 : nil } ?? nil,
            truncated: matching.count > slice.count
        )
    }

    static func export(_ stored: StoredEvent) -> ExportedEvent {
        var kind = "unknown"
        var source: String?
        var direction: String?
        var method: String?
        var url: String?
        var status: Int?
        var contentType: String?
        var frameOrigin: String?
        var isForMainFrame: Bool?
        var duration: Double?
        var message: String?
        var actionKind: String?
        var actionStatus: String?
        var urlAfter: String?
        var bodiesOmitted = false
        var truncated = false

        switch stored.event {
        case .capture(let capture):
            switch capture {
            case .page(let page):
                kind = "page.\(page.kind.rawValue)"
                url = ExportSanitizer.url(page.url)
                (message, truncated) = ExportSanitizer.bounded(page.message)
            case .response(let response):
                kind = "network"
                source = response.source.rawValue
                direction = response.direction?.rawValue
                method = response.method
                url = ExportSanitizer.url(response.url)
                status = response.status
                contentType = response.contentType
                frameOrigin = response.frame?.securityOrigin
                isForMainFrame = response.frame?.isMainFrame
                duration = response.durationMilliseconds
                (message, truncated) = ExportSanitizer.bounded(response.errorDescription)
                bodiesOmitted = true
            case .nativeNetwork(let native):
                kind = "nativeNetwork.\(native.phase.rawValue)"
                method = native.method
                url = ExportSanitizer.url(native.url)
                status = native.status
                contentType = native.mimeType
                isForMainFrame = native.isForMainFrame
                message = native.navigationType
            case .action(let result):
                kind = "action"
                actionKind = result.kind.rawValue
                actionStatus = result.status.rawValue
                url = ExportSanitizer.url(result.urlBefore)
                urlAfter = ExportSanitizer.url(result.urlAfter)
                (message, truncated) = ExportSanitizer.bounded(result.message)
            case .console(let console):
                kind = "console.\(console.level)"
                message = "[omitted]"
                bodiesOmitted = true
            case .scriptError(let error):
                kind = "scriptError"
                url = ExportSanitizer.url(error.url)
                (message, truncated) = ExportSanitizer.bounded(error.message)
            case .accessibility, .browserState:
                kind = "omitted"
            }
        case .dialog(let dialogKind, let dialogMessage):
            kind = "dialog.\(dialogKind)"
            (message, truncated) = ExportSanitizer.bounded(dialogMessage)
        case .lifecycle(let name):
            kind = "lifecycle.\(name)"
        }

        return ExportedEvent(
            sequence: stored.sequence,
            capturedAt: stored.capturedAt,
            pageEpoch: stored.pageEpoch,
            kind: kind,
            source: source,
            direction: direction,
            method: method,
            url: url,
            status: status,
            contentType: contentType,
            frameOrigin: frameOrigin,
            isForMainFrame: isForMainFrame,
            durationMilliseconds: duration,
            message: message,
            actionKind: actionKind,
            actionStatus: actionStatus,
            urlAfter: urlAfter,
            bodiesOmitted: bodiesOmitted,
            truncated: truncated
        )
    }
}
