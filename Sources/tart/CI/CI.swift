struct CI {
  private static let rawVersion = "${VERSION}"

  static var version: String {
    rawVersion.expanded() ? rawVersion : "SNAPSHOT"
  }

  static var release: String? {
    rawVersion.expanded() ? "tart@\(rawVersion)" : nil
  }
}

private extension String {
  func expanded() -> Bool {
    !isEmpty && !starts(with: "$")
  }
}
