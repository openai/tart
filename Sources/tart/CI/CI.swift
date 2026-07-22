struct CI {
  private static let rawVersion = "${VERSION}"

  static var version: String {
    rawVersion.expanded() ? rawVersion : "SNAPSHOT"
  }

  /// Same as `version`, but always a valid semver with major ≥ 2 so the guest
  /// agent's `/dev/cu.tart-version-<semver>` Tart-detection probe accepts it.
  /// For non-tagged dev builds we'd otherwise emit `SNAPSHOT`, which the agent
  /// can't parse — it then thinks it isn't running on Tart and bails out with
  /// "operation not permitted" when it tries to SIGTERM its launchd parent.
  static var deviceVersion: String {
    rawVersion.expanded() ? rawVersion : "99.0.0"
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
