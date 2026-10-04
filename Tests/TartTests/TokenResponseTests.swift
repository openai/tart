import XCTest
@testable import tart

final class TokenResponseTests: XCTestCase {
  func testFractionalIssuedAt() throws {
    for timestamp in ["1970-01-01T00:00:00.125Z", "1970-01-01T01:30:00.125+01:30", "1970-01-01T00:00:00.125000000Z"] {
      let data = Data("{\"token\":\"test-token\",\"expires_in\":3600,\"issued_at\":\"\(timestamp)\"}".utf8)
      let response = try TokenResponse.parse(fromData: data)

      XCTAssertEqual(response.issuedAt!.timeIntervalSince1970, 0.125, accuracy: 0.0001)
      XCTAssertEqual(response.tokenExpiresAt.timeIntervalSince1970, 3600.125, accuracy: 0.0001)
      XCTAssertFalse(response.isValid())
    }
  }

  func testBasic() throws {
    var expectedTokenExpiresAtRange = DateInterval()
    let tokenResponseRaw = Data("{\"token\":\"some token\"}".utf8)
    let tokenResponse = try TokenResponse.parse(fromData: tokenResponseRaw)

    XCTAssertEqual(tokenResponse.token, "some token")

    expectedTokenExpiresAtRange.end = Date().addingTimeInterval(60)
    XCTAssertTrue(expectedTokenExpiresAtRange.contains(tokenResponse.tokenExpiresAt))

    XCTAssertTrue(tokenResponse.isValid())
  }

  func testExpirationBasic() throws {
    var expectedTokenExpiresAtRange = DateInterval()
    let tokenResponseRaw = Data("{\"token\":\"some token\",\"expires_in\":2}".utf8)
    let tokenResponse = try TokenResponse.parse(fromData: tokenResponseRaw)

    XCTAssertEqual(tokenResponse.expiresIn, 2)

    expectedTokenExpiresAtRange.end = Date().addingTimeInterval(2)
    XCTAssertTrue(expectedTokenExpiresAtRange.contains(tokenResponse.tokenExpiresAt))

    XCTAssertTrue(tokenResponse.isValid())
    _ = XCTWaiter.wait(for: [expectation(description: "Wait 3 seconds for the token to become invalid")], timeout: 2)
    XCTAssertFalse(tokenResponse.isValid())
  }

  func testExpirationWithIssuedAt() throws {
    let tokenResponseRaw = Data("{\"token\":\"some token\",\"expires_in\":3600,\"issued_at\":\"1970-01-01T00:00:00Z\"}".utf8)
    let tokenResponse = try TokenResponse.parse(fromData: tokenResponseRaw)

    XCTAssertEqual(Date(timeIntervalSince1970: 3600), tokenResponse.tokenExpiresAt)
    XCTAssertFalse(tokenResponse.isValid())
  }
}
