import Foundation

/// OPML import/export, the format every RSS reader uses to move subscriptions.
enum OPML {
    struct Outline {
        var title: String?
        var url: String
    }

    static func export(_ feeds: [Feed]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>FeedBuddy subscriptions</title>
            <dateCreated>\(httpDate(Date()))</dateCreated>
          </head>
          <body>

        """
        for f in feeds {
            let title = escape(f.title)
            xml += "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(escape(f.url))\"/>\n"
        }
        xml += "  </body>\n</opml>\n"
        return Data(xml.utf8)
    }

    /// Every outline with an xmlUrl, at any nesting depth (folders are flattened).
    static func parse(_ data: Data) throws -> [Outline] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FeedError("Not a valid OPML file: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        return delegate.outlines
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var outlines: [Outline] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard name.lowercased() == "outline" else { return }
            let attrs = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            guard let url = attrs["xmlurl"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
            outlines.append(Outline(title: attrs["title"] ?? attrs["text"], url: url))
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }
}
