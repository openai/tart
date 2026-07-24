import Foundation
import System

extension URL {
  func accessDate() throws -> Date {
    let attrs = try resourceValues(forKeys: [.contentAccessDateKey])
    return attrs.contentAccessDate!
  }

  func updateAccessDate(_ accessDate: Date = Date()) throws {
    let attrs = try resourceValues(forKeys: [.contentModificationDateKey])
    let modificationDate = attrs.contentModificationDate!

    let times = [accessDate.asTimeval(), modificationDate.asTimeval()]
    let ret = utimes(path, times)
    if ret != 0 {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.FailedToUpdateAccessDate("utimes(2) failed: \(details)")
    }
  }
}

extension Date {
  func asTimeval() -> timeval {
    let seconds = floor(timeIntervalSince1970)
    let microseconds = (timeIntervalSince1970 - seconds) * 1_000_000

    return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds))
  }
}
