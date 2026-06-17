import MacTMUXCore
import Foundation

struct LogLinkScanCache {
    private struct CachedLink {
        var link: DetectedLogLink
        var sequence: Int
        var lineID: String
    }

    private var contextID: String?
    private var scannedLineIDs = Set<String>()
    private var baseURL: URL?
    private var linksByURLString: [String: CachedLink] = [:]

    mutating func reset(contextID: String? = nil) {
        self.contextID = contextID
        scannedLineIDs = []
        baseURL = nil
        linksByURLString = [:]
    }

    mutating func update(contextID: String, lines: [LogLine]) -> [DetectedLogLink] {
        if self.contextID != contextID {
            reset(contextID: contextID)
        }

        let retainedLineIDs = Set(lines.map(\.id))
        let needsRebuild = pruneRetainedState(retainedLineIDs: retainedLineIDs)
        var shouldRescanLinesWithBaseURL = false
        for line in lines where scannedLineIDs.insert(line.id).inserted {
            let links = LogLinkDetector.detectLinks(in: line.text, maxCount: 16, baseURL: baseURL)
            cache(links, sequence: line.sequence, lineID: line.id)
            if updateBaseURL(from: links) {
                shouldRescanLinesWithBaseURL = true
            }
        }

        if shouldRescanLinesWithBaseURL || needsRebuild, let baseURL {
            rebuildLinks(from: lines, baseURL: baseURL)
        } else if needsRebuild {
            rebuildLinks(from: lines, baseURL: nil)
        }

        return sortedLinks()
    }

    private mutating func rebuildLinks(from lines: [LogLine], baseURL: URL?) {
        linksByURLString = [:]
        for line in lines {
            let links = LogLinkDetector.detectLinks(in: line.text, maxCount: 16, baseURL: baseURL)
            cache(links, sequence: line.sequence, lineID: line.id)
        }
    }

    private mutating func pruneRetainedState(retainedLineIDs: Set<String>) -> Bool {
        let previousLinkCount = linksByURLString.count
        scannedLineIDs.formIntersection(retainedLineIDs)
        linksByURLString = linksByURLString.filter { retainedLineIDs.contains($0.value.lineID) }
        return linksByURLString.count != previousLinkCount
    }

    private func sortedLinks() -> [DetectedLogLink] {
        linksByURLString.values
            .sorted { left, right in
                if left.sequence == right.sequence {
                    return left.link.urlString < right.link.urlString
                }
                return left.sequence > right.sequence
            }
            .prefix(LogLinkDetector.defaultMaxCount)
            .map(\.link)
    }

    private mutating func cache(_ links: [DetectedLogLink], sequence: Int, lineID: String) {
        for link in links {
            let existing = linksByURLString[link.urlString]
            if existing == nil || sequence >= existing!.sequence {
                linksByURLString[link.urlString] = CachedLink(link: link, sequence: sequence, lineID: lineID)
            }
        }
    }

    private mutating func updateBaseURL(from links: [DetectedLogLink]) -> Bool {
        guard let inferredBaseURL = links.lazy.compactMap(Self.developmentBaseURL(from:)).first,
              inferredBaseURL != baseURL else {
            return false
        }

        baseURL = inferredBaseURL
        return true
    }

    private static func developmentBaseURL(from link: DetectedLogLink) -> URL? {
        guard var components = URLComponents(string: link.urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              isLocalDevelopmentHost(host) else {
            return nil
        }

        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" || host == "::1"
    }
}
