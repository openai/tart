import Foundation

public protocol Logger {
  func appendNewLine(_ line: String) -> Void
  func updateLastLine(_ line: String) -> Void
}

var defaultLogger: Logger = {
  if ProcessInfo.processInfo.environment["CI"] != nil || isatty(STDOUT_FILENO) == 0 {
    return SimpleConsoleLogger()
  } else {
    return InteractiveConsoleLogger()
  }
}()

public class InteractiveConsoleLogger: Logger {
  private let eraseCursorDown = "\u{001B}[J" // clear entire line
  private let moveUp = "\u{001B}[1A" // move one line up
  private let moveBeginningOfLine = "\r" // 

  public init() {

  }

  public func appendNewLine(_ line: String) {
    print(line, terminator: "\n")
  }

  public func updateLastLine(_ line: String) {
    print(moveUp, moveBeginningOfLine, eraseCursorDown, line, separator: "", terminator: "\n")
  }
}

public class SimpleConsoleLogger: Logger {
  public init() {

  }

  public func appendNewLine(_ line: String) {
    print(line, terminator: "\n")
  }

  public func updateLastLine(_ line: String) {
    print(line, terminator: "\n")
  }
}
