import Foundation
import System

extension URL {
  func accessDate() throws -> Date {
    let attrs = try resourceValues(forKeys: [.contentAccessDateKey])
    return attrs.contentAccessDate!
  }

  func updateAccessDate(_ accessDate: Date = Date()) throws {
    let times = [accessDate.asTimespec(), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
    let ret = utimensat(AT_FDCWD, path, times, 0)
    if ret != 0 {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.FailedToUpdateAccessDate("utimensat(2) failed: \(details)")
    }
  }
}

extension Date {
  func asTimespec() -> timespec {
    let seconds = floor(timeIntervalSince1970)
    let nanoseconds = (timeIntervalSince1970 - seconds) * 1_000_000_000

    return timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
  }
}
