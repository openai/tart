import Foundation
import Antlr4

struct Reference: Comparable, Hashable, CustomStringConvertible {
  enum ReferenceType: Comparable {
    case Tag
    case Digest
  }

  let type: ReferenceType
  let value: String

  var fullyQualified: String {
    get {
      switch type {
      case .Tag:
        return ":" + value
      case .Digest:
        return "@" + value
      }
    }
  }

  init(tag: String) {
    type = .Tag
    value = tag
  }

  init(digest: String) {
    type = .Digest
    value = digest
  }

  static func <(lhs: Reference, rhs: Reference) -> Bool {
    if lhs.type != rhs.type {
      return lhs.type < rhs.type
    } else {
      return lhs.value < rhs.value
    }
  }

  var description: String {
    get {
      fullyQualified
    }
  }
}

class ReferenceCollector: ReferenceBaseListener {
  var host: String? = nil
  var port: String? = nil
  var namespace: String? = nil
  var reference: String? = nil

  override func exitHost(_ ctx: ReferenceParser.HostContext) {
    host = ctx.getText()
  }

  override func exitPort(_ ctx: ReferenceParser.PortContext) {
    port = ctx.getText()
  }

  override func exitNamespace(_ ctx: ReferenceParser.NamespaceContext) {
    namespace = ctx.getText()
  }

  override func exitReference(_ ctx: ReferenceParser.ReferenceContext) {
    reference = ctx.getText()
  }
}

class ErrorCollector: BaseErrorListener {
  var error: String? = nil

  override func syntaxError<T>(_ recognizer: Recognizer<T>, _ offendingSymbol: AnyObject?, _ line: Int, _ charPositionInLine: Int, _ msg: String, _ e: AnyObject?) {
    if error == nil {
      error = "\(msg) (character \(charPositionInLine + 1))"
    }
  }
}

struct RemoteName: Comparable, Hashable, CustomStringConvertible {
  var host: String
  var namespace: String
  var reference: Reference

  init(host: String, namespace: String, reference: Reference) {
    self.host = host
    self.namespace = namespace
    self.reference = reference
  }

  init(_ name: String) throws {
    let errorCollector = ErrorCollector()
    let inputStream = ANTLRInputStream(name)
    let lexer = ReferenceLexer(inputStream)
    lexer.removeErrorListeners()
    lexer.addErrorListener(errorCollector)

    let tokenStream = CommonTokenStream(lexer)
    let parser = try ReferenceParser(tokenStream)
    parser.removeErrorListeners()
    parser.addErrorListener(errorCollector)

    let referenceCollector = ReferenceCollector()
    try ParseTreeWalker().walk(referenceCollector, try parser.root())

    if let error = errorCollector.error {
      throw RuntimeError.FailedToParseRemoteName("\(error)")
    }

    host = referenceCollector.host!
    if let port = referenceCollector.port {
      host += ":" + port
    }
    namespace = referenceCollector.namespace!
    if let reference = referenceCollector.reference {
      if reference.starts(with: "@sha256:") {
        self.reference = Reference(digest: String(reference.dropFirst(1)))
      } else if reference.starts(with: ":") {
        self.reference = Reference(tag: String(reference.dropFirst(1)))
      } else {
        throw RuntimeError.FailedToParseRemoteName("unknown reference format")
      }
    } else {
      self.reference = Reference(tag: "latest")
    }
  }

  static func <(lhs: RemoteName, rhs: RemoteName) -> Bool {
    if lhs.host != rhs.host {
      return lhs.host < rhs.host
    } else if lhs.namespace != rhs.namespace {
      return lhs.namespace < rhs.namespace
    } else {
      return lhs.reference < rhs.reference
    }
  }

  var description: String {
    "\(host)/\(namespace)\(reference.fullyQualified)"
  }
}

extension Array where Self.Element == ClosedRange<UInt8> {
  func asCharacterSet() -> CharacterSet {
    let characters = self.joined().map { String(UnicodeScalar($0)) }.joined()
    return CharacterSet(charactersIn: characters)
  }
}
