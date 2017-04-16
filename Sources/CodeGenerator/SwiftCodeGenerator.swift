// swiftlint:disable line_length

import SchemaParser

public typealias SwiftCode = String
public typealias LineOfCode = SwiftCode

public protocol SwiftCodeConvertible {
    func toSwiftCode(indentedBy indentChars: String) -> SwiftCode
}

public protocol LinesOfCodeConvertible: SwiftCodeConvertible {
    func toLinesOfCode(at indentation: Indentation) -> [LineOfCode]
}

extension LinesOfCodeConvertible {
    public func toSwiftCode(indentedBy indentChars: String = "    ") -> SwiftCode {
        let indentation = Indentation(chars: indentChars)
        let linesOfCode = toLinesOfCode(at: indentation)
        return linesOfCode.joined(separator: "\n")
    }
}

struct SwiftCodeGenerator {
    /// This method is used when only one Swift file is being generated.
    static func generateCode(for types: [SwiftCodeConvertible], _ clients: [SwiftClientClass]) -> String {
        return [
            preamble,
            "//",
            "// MARK: - SOAP Structures",
            "//",
            types.map { $0.toSwiftCode(indentedBy: "    ") }
                .filter { $0 != "" }
                .joined(separator: "\n\n"),
            "",
            "//",
            "// MARK: - SOAP Client",
            "//",
            clients.map { $0.toSwiftCode(indentedBy: "    ") }
                .filter { $0 != "" }
                .joined(separator: "\n\n"),
            ""].joined(separator: "\n")
    }

    private static let preamble = [
        "// This file was generated by Lark. https://github.com/Bouke/Lark",
        "",
        "import Alamofire",
        "import Foundation",
        "import Lark",
        ""].joined(separator: "\n")
}

public struct Indentation {
    private let chars: String
    private let level: Int
    private let value: String

    init(chars: String, level: Int = 0) {
        precondition(level >= 0)
        self.chars = chars
        self.level = level
        self.value = String(repeating: chars, count: level)
    }

    func apply(toLineOfCode lineOfCode: LineOfCode) -> LineOfCode {
        return value + lineOfCode
    }

    func apply(toFirstLine firstLine: LineOfCode,
               nestedLines: [LineOfCode],
               andLastLine lastLine: LineOfCode) -> [LineOfCode] {
        return apply(
            toFirstLine: firstLine,
            nestedLines: { indentation in nestedLines.map { line in indentation.apply(toLineOfCode: line) } },
            andLastLine: lastLine)
    }

    func apply(toFirstLine firstLine: LineOfCode,
               nestedLines generateNestedLines: (Indentation) -> [LineOfCode],
               andLastLine lastLine: LineOfCode) -> [LineOfCode] {
        let first  = apply(toLineOfCode: firstLine)
        let middle = generateNestedLines(self.increased())
        let last   = apply(toLineOfCode: lastLine)
        return [first] + middle + [last]
    }

    private func increased() -> Indentation {
        return Indentation(chars: chars, level: level + 1)
    }
}

extension SwiftBuiltin {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return []
    }
}

// MARK: - SOAP Types

extension SwiftTypeClass {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        let baseType = base?.name ?? "XMLDeserializable"
        return indentation.apply(
            toFirstLine: "class \(name): \(baseType) {",
            nestedLines:      linesOfCodeForBody(at:),
            andLastLine: "}")
    }

    private func linesOfCodeForBody(at indentation: Indentation) -> [LineOfCode] {
        var lines: [LineOfCode] = []
        lines += linesOfCodeForProperties(at: indentation)
        lines += initializer(at: indentation)
        lines += deserializer(at: indentation)
        lines += serializer(at: indentation)
        lines += linesOfCodeForNestedClasses(at: indentation)
        lines += members.flatMap { $0.toLinesOfCode(at: indentation) }
        return lines
    }

    private func initializer(at indentation: Indentation) -> [LineOfCode] {
        let superInit: [LineOfCode] = base.map { _ in
            let arguments = inheritedProperties
                .map { "\($0.name): \($0.name)" }
                .joined(separator: ", ")
            return ["super.init(\(arguments))"]
        } ?? []

        let override = properties.count == 0 && base != nil ? "override " : ""

        let signature = (inheritedProperties + properties)
            .map {
                let base = "\($0.name): \($0.type.toSwiftCode())"
                let `default`: String
                switch $0.type {
                case .optional, .nillable: `default` = " = nil"
                default: `default` = ""
                }
                return "\(base)\(`default`)"
            }
            .joined(separator: ", ")

        return indentation.apply(
            toFirstLine: "\(override)init(\(signature)) {",
            nestedLines:
                properties.map { property in
                    "self.\(property.name) = \(property.name)"
                } + superInit,
            andLastLine: "}")
    }

    private func deserializer(at indentation: Indentation) -> [LineOfCode] {
        let superInit: [LineOfCode] = base.map { _ in ["try super.init(deserialize: element)"] } ?? []
        return indentation.apply(
            toFirstLine: "required init(deserialize element: XMLElement) throws {",
            nestedLines:
                properties.flatMap { property -> [LineOfCode] in
                    let element = property.element.name
                    let throwNoElement = "throw XMLDeserializationError.noElementWithName(QualifiedName(uri: \"\(element.uri)\", localName: \"\(element.localName)\"))"
                    switch property.type {
                    case let .identifier(identifier):
                        return [
                            "do {",
                            "    guard let node = element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").first else {",
                            "        \(throwNoElement)",
                            "    }",
                            "    self.\(property.name) = try \(identifier)(deserialize: node)",
                            "}"
                        ]
                    case let .optional(.identifier(identifier)):
                        return [
                            "do {",
                            "    if let node = element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").first {",
                            "        self.\(property.name) = try \(identifier)(deserialize: node)",
                            "    } else {",
                            "        self.\(property.name) = nil",
                            "    }",
                            "}"
                        ]
                    case let .nillable(.identifier(identifier)):
                        return [
                            "do {",
                            "    guard let node = element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").first else {",
                            "        \(throwNoElement)",
                            "    }",
                            "    if node.attribute(forLocalName: \"nil\", uri: NS_XSI)?.stringValue != \"true\" {",
                            "        self.\(property.name) = try \(identifier)(deserialize: node)",
                            "    } else {",
                            "        self.\(property.name) = nil",
                            "    }",
                            "}"
                        ]
                    case let .optional(.nillable(.identifier(identifier))):
                        return [
                            "do {",
                            "    if let node = element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").first,",
                            "            node.attribute(forLocalName: \"nil\", uri: NS_XSI)?.stringValue != \"true\" {",
                            "        self.\(property.name) = try \(identifier)(deserialize: node)",
                            "    } else {",
                            "        self.\(property.name) = nil",
                            "    }",
                            "}"
                        ]
                    case let .array(.identifier(identifier)):
                        return [
                            "self.\(property.name) = try element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").map(\(identifier).init(deserialize:))"
                        ]
                    case let .array(.nillable(.identifier(identifier))):
                        return [
                            "self.\(property.name) = try element.elements(forLocalName: \"\(element.localName)\", uri: \"\(element.uri)\").map { node in",
                            "    if node.attribute(forLocalName: \"nil\", uri: NS_XSI)?.stringValue != \"true\" {",
                            "        return try \(identifier)(deserialize: node)",
                            "    } else {",
                            "        return nil",
                            "    }",
                            "}"
                        ]
                    default:
                        // Should not happen as the cases should match whats generated by `SwiftType(init:)`
                        fatalError("Type \(property.type) not supported")
                    }
                } + superInit,
            andLastLine: "}")
    }

    private func serializer(at indentation: Indentation) -> [LineOfCode] {
        let override = base.map { _ in "override " } ?? ""
        let superSerialize: [LineOfCode] = base.map { _ in ["try super.serialize(element)"] } ?? []
        return indentation.apply(
            toFirstLine: "\(override)func serialize(_ element: XMLElement) throws {",
            nestedLines:
            properties.flatMap { property -> [LineOfCode] in
                let element = property.element.name
                let setNil = "addAttribute(XMLNode.attribute(prefix: \"xsi\", localName: \"nil\", uri: NS_XSI, stringValue: \"true\"))"
                switch property.type {
                case .identifier:
                    return [
                        "let \(property.name)Node = element.createChildElement(localName: \"\(element.localName)\", uri: \"\(element.uri)\")",
                        "try \(property.name).serialize(\(property.name)Node)"
                    ]
                case .optional(.identifier), .optional(.nillable(.identifier)):
                    return [
                        "if let \(property.name) = \(property.name) {",
                        "    let \(property.name)Node = element.createChildElement(localName: \"\(element.localName)\", uri: \"\(element.uri)\")",
                        "    try \(property.name).serialize(\(property.name)Node)",
                        "}"
                    ]
                case .nillable(.identifier):
                    return [
                        "let \(property.name)Node = element.createChildElement(localName: \"\(element.localName)\", uri: \"\(element.uri)\")",
                        "if let \(property.name) = \(property.name) {",
                        "    try \(property.name).serialize(\(property.name)Node)",
                        "} else {",
                        "    \(property.name)Node.\(setNil)",
                        "}"
                    ]
                case .array(.identifier):
                    return [
                        "for item in \(property.name) {",
                        "    let itemNode = element.createChildElement(localName: \"\(element.localName)\", uri: \"\(element.uri)\")",
                        "    try item.serialize(itemNode)",
                        "}"
                    ]
                case .array(.nillable(.identifier)):
                    return [
                        "for item in \(property.name) {",
                        "    let itemNode = element.createChildElement(localName: \"\(element.localName)\", uri: \"\(element.uri)\")",
                        "    if let item = item {",
                        "        try item.serialize(itemNode)",
                        "    } else {",
                        "        itemNode.\(setNil)",
                        "    }",
                        "}"
                    ]
                default:
                    fatalError("Type \(property.type) not supported")
                }
            } + superSerialize,
            andLastLine: "}")
    }

    private func linesOfCodeForProperties(at indentation: Indentation) -> [LineOfCode] {
        return sortedProperties.map { property in
            let propertyCode = property.toLineOfCode()
            return indentation.apply(toLineOfCode: propertyCode)
        }
    }

    private var inheritedProperties: [SwiftProperty] {
        return (base?.inheritedProperties ?? []) + (base?.properties ?? [])
    }

    private var sortedProperties: [SwiftProperty] {
        return properties.sorted { (lhs, rhs) -> Bool in
            return lhs.name.compare(rhs.name) == .orderedAscending
        }
    }

    private func linesOfCodeForNestedClasses(at indentation: Indentation) -> [LineOfCode] {
        return sortedNestedTypes.flatMap { $0.toLinesOfCode(at: indentation) }
    }

    private var sortedNestedTypes: [SwiftMetaType] {
        return nestedTypes.sorted(by: { (lhs, rhs) -> Bool in
            return lhs.name.compare(rhs.name) == .orderedAscending
        })
    }
}

extension SwiftType {
    func toSwiftCode() -> SwiftCode {
        switch self {
        case let .identifier(name): return name
        case let .optional(.nillable(type)): return "\(type.toSwiftCode())?"
        case let .optional(type): return "\(type.toSwiftCode())?"
        case let .nillable(type): return "\(type.toSwiftCode())?"
        case let .array(type): return "[\(type.toSwiftCode())]"
        }
    }
}

extension SwiftProperty {
    func toLineOfCode() -> LineOfCode {
        return "var \(name): \(type.toSwiftCode())"
    }
}

extension SwiftParameter {
    func toSwiftCode() -> SwiftCode {
        return "\(name): \(type.toSwiftCode())"
    }
}

extension SwiftEnum {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return indentation.apply(
            toFirstLine: "enum \(name): \(rawType.toSwiftCode()), XMLSerializable, XMLDeserializable, StringSerializable, StringDeserializable {",
            nestedLines:      linesOfCodeForBody(at:),
            andLastLine: "}")
    }

    private func linesOfCodeForBody(at indentation: Indentation) -> [LineOfCode] {
        return linesOfCodeForCases(at: indentation) +
            linesOfCodeForXMLDeserializer(at: indentation) +
            linesOfCodeForXMLSerializer(at: indentation) +
            linesOfCodeForStringDeserializer(at: indentation) +
            linesOfCodeForStringSerializer(at: indentation)
    }

    private func linesOfCodeForCases(at indentation: Indentation) -> [LineOfCode] {
        return sortedCases.map { (name, rawValue) in
            return indentation.apply(toLineOfCode: "case \(name) = \"\(rawValue)\"")
        }
    }

    private var sortedCases: [(String, String)] {
        return cases.sorted(by: { return $0.key < $1.key })
    }

    private func linesOfCodeForXMLDeserializer(at indentation: Indentation) -> [LineOfCode] {
        // TODO: no force unwraps
        return indentation.apply(
            toFirstLine: "init(deserialize element: XMLElement) throws {",
            nestedLines: ["self.init(rawValue: element.stringValue!)!"],
            andLastLine: "}")
    }

    private func linesOfCodeForXMLSerializer(at indentation: Indentation) -> [LineOfCode] {
        // TODO: no force unwraps
        return indentation.apply(
            toFirstLine: "func serialize(_ element: XMLElement) throws {",
            nestedLines: ["element.stringValue = self.rawValue"],
            andLastLine: "}")
    }

    private func linesOfCodeForStringDeserializer(at indentation: Indentation) -> [LineOfCode] {
        // TODO: no force unwraps
        return indentation.apply(
            toFirstLine: "init(string: String) throws {",
            nestedLines: ["self.init(rawValue: string)!"],
            andLastLine: "}")
    }

    private func linesOfCodeForStringSerializer(at indentation: Indentation) -> [LineOfCode] {
        // TODO: no force unwraps
        return indentation.apply(
            toFirstLine: "func serialize() throws -> String {",
            nestedLines: ["return self.rawValue"],
            andLastLine: "}")
    }
}

extension SwiftTypealias {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return ["typealias \(name) = \(type.toSwiftCode())"].map(indentation.apply(toLineOfCode:))
    }
}

extension SwiftList {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return indentation.apply(
            toFirstLine: "struct \(name): StringSerializableList {",
            nestedLines:    linesOfCodeForBody(at:),
            andLastLine: "}")
    }

    private func linesOfCodeForBody(at indentation: Indentation) -> [LineOfCode] {
        return nestedTypes.flatMap { $0.toLinesOfCode(at: indentation) }
            + ["var _contents: [\(element.toSwiftCode())] = []"].map(indentation.apply(toLineOfCode:))
            + indentation.apply(
                toFirstLine: "init(_ contents: [\(element.toSwiftCode())]) {",
                nestedLines: ["_contents = contents"],
                andLastLine: "}")
    }
}

// MARK: - SOAP Client

extension SwiftClientClass {
    public func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return indentation.apply(
            toFirstLine: "class \(name): Lark.Client {",
            nestedLines:      linesOfCodeForMembers(at:),
            andLastLine: "}")
    }

    private func linesOfCodeForMembers(at indentation: Indentation) -> [LineOfCode] {
        return properties(at: indentation)
            + initializer(at: indentation)
            + methods.flatMap { $0.toLinesOfCode(at: indentation) }
    }

    private func properties(at indentation: Indentation) -> [LineOfCode] {
        guard case let .soap11(endpoint) = port.address else {
            fatalError("Expected SOAP 1.1 port")
        }

        return [
            "static let defaultEndpoint = URL(string: \"\(endpoint)\")!"
            ].map { indentation.apply(toLineOfCode: $0) }
    }

    private func initializer(at indentation: Indentation) -> [LineOfCode] {
        return indentation.apply(
            toFirstLine: "override init(endpoint: URL = \(name).defaultEndpoint, sessionManager: SessionManager = SessionManager()) {",
            nestedLines: [
                "super.init(endpoint: endpoint, sessionManager: sessionManager)"
            ],
            andLastLine: "}")
    }
}

extension ServiceMethod: LinesOfCodeConvertible {
    func toLinesOfCode(at indentation: Indentation) -> [LineOfCode] {
        return syncCall(at: indentation) + asyncCall(at: indentation)
    }

    func syncCall(at indentation: Indentation) -> [LineOfCode] {
        return [
            "/// Call \(name) synchronously",
            "func \(name)(_ parameter: \(input.type)) throws -> \(output.type) {",
            "    let response = try call(",
            "        action: URL(string: \"\(action?.absoluteString ?? "")\")!,",
            "        serialize: { envelope in",
            "            let node = XMLElement(prefix: \"ns0\", localName: \"\(input.element.localName)\", uri: \"\(input.element.uri)\")",
            "            node.addNamespace(XMLNode.namespace(withName: \"ns0\", stringValue: \"\(input.element.uri)\") as! XMLNode)",
            "            try parameter.serialize(node)",
            "            envelope.body.addChild(node)",
            "            return envelope",
            "        },",
            "        deserialize: { envelope -> \(output.type) in",
            "            guard let node = envelope.body.elements(forLocalName: \"\(output.element.localName)\", uri: \"\(output.element.uri)\").first else {",
            "                throw XMLDeserializationError.noElementWithName(QualifiedName(uri: \"\(output.element.uri)\", localName: \"\(output.element.localName)\"))",
            "            }",
            "            return try \(output.type)(deserialize: node)",
            "        })",
            "    return try response.result.resolve()",
            "}"
        ].map(indentation.apply(toLineOfCode:))
    }

    func asyncCall(at indentation: Indentation) -> [LineOfCode] {
        return [
            "/// Call \(name) asynchronously",
            "@discardableResult func \(name)(_ parameter: \(input.type), completionHandler: @escaping (Result<\(output.type)>) -> Void) -> DataRequest {",
            "    return call(",
            "        action: URL(string: \"\(action?.absoluteString ?? "")\")!,",
            "        serialize: { envelope in",
            "            let node = XMLElement(prefix: \"ns0\", localName: \"\(input.element.localName)\", uri: \"\(input.element.uri)\")",
            "            node.addNamespace(XMLNode.namespace(withName: \"ns0\", stringValue: \"\(input.element.uri)\") as! XMLNode)",
            "            try parameter.serialize(node)",
            "            envelope.body.addChild(node)",
            "            return envelope",
            "        },",
            "        deserialize: { envelope in",
            "            guard let node = envelope.body.elements(forLocalName: \"\(output.element.localName)\", uri: \"\(output.element.uri)\").first else {",
            "                throw XMLDeserializationError.noElementWithName(QualifiedName(uri: \"\(output.element.uri)\", localName: \"\(output.element.localName)\"))",
            "            }",
            "            return try \(output.type)(deserialize: node)",
            "        },",
            "        completionHandler: completionHandler)",
            "}",
        ].map(indentation.apply(toLineOfCode:))
    }
}
