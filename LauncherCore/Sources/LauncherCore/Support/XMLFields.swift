import Foundation

/// The text and the attributes of each element of a small XML document, by element name. The
/// documents it reads name each element once.
struct XMLFields {
    private(set) var texts: [String: String] = [:]
    private(set) var attributes: [String: [String: String]] = [:]

    init?(data: Data) {
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        guard parser.parse() else { return nil }
        texts = reader.texts
        attributes = reader.attributes
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var texts: [String: String] = [:]
        var attributes: [String: [String: String]] = [:]
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            self.attributes[element] = attributes
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            texts[element] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension String {
    var xmlEscaped: String {
        var escaped = ""
        for character in self {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
