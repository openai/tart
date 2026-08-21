import XCTest
@testable import tart

final class VMConfigTests: XCTestCase {
  func testVMDisplayConfig() throws {
    // Defaults units (points)
    var vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: nil), vmDisplayConfig)

    // Explicit units (points)
    vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678pt")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: .point), vmDisplayConfig)

    // Explicit units (pixels)
    vmDisplayConfig = VMDisplayConfig.init(argument: "1234x5678px")
    XCTAssertEqual(VMDisplayConfig(width: 1234, height: 5678, unit: .pixel), vmDisplayConfig)
  }

  func testEffectivePixelsPerInchUsesConfiguredValue() throws {
    let config = VMDisplayConfig(width: 3200, height: 1800, unit: .pixel, ppi: 220)
    XCTAssertEqual(220, config.effectivePixelsPerInch)
  }

  func testEffectivePixelsPerInchDefaultsTo72WhenUnset() throws {
    // Upstream behavior: a pixel display with no PPI hint stays non-Retina (72 PPI).
    let config = VMDisplayConfig(width: 1234, height: 5678, unit: .pixel, ppi: nil)
    XCTAssertEqual(72, config.effectivePixelsPerInch)
  }

  func testParsesPixelsPerInchSuffix() throws {
    let config = VMDisplayConfig(argument: "3200x1800px@220")
    XCTAssertEqual(VMDisplayConfig(width: 3200, height: 1800, unit: .pixel, ppi: 220), config)
  }

  func testWithoutSuffixHasNilPixelsPerInch() throws {
    // Backward compatibility: existing "WIDTHxHEIGHT[pt|px]" strings carry no PPI.
    XCTAssertEqual(
      VMDisplayConfig(width: 1234, height: 5678, unit: .pixel, ppi: nil),
      VMDisplayConfig(argument: "1234x5678px"))
  }

  func testDescriptionRoundTripsPixelsPerInch() throws {
    let config = VMDisplayConfig(width: 3200, height: 1800, unit: .pixel, ppi: 220)
    XCTAssertEqual("3200x1800px@220", config.description)
    XCTAssertEqual(config, VMDisplayConfig(argument: config.description))
  }

  func testParsesPixelsPerInchWithoutExplicitUnit() throws {
    let config = VMDisplayConfig(argument: "3200x1800@220")
    XCTAssertEqual(VMDisplayConfig(width: 3200, height: 1800, unit: nil, ppi: 220), config)
  }

  func testMalformedPixelsPerInchDegradesToNil() throws {
    // A non-numeric PPI is ignored (falls back to the 72 default) rather than
    // failing the parse — consistent with the parser's lenient dimensions.
    let config = VMDisplayConfig(argument: "3200x1800px@notanumber")
    XCTAssertEqual(VMDisplayConfig(width: 3200, height: 1800, unit: .pixel, ppi: nil), config)
    XCTAssertEqual(72, config.effectivePixelsPerInch)
  }

  func testRejectsNonPositivePixelsPerInchWhenParsing() throws {
    // A zero or negative PPI is meaningless and must not persist — it would
    // otherwise reach VZMacGraphicsDisplayConfiguration and fail to build the
    // display instead of falling back to the 72 default.
    XCTAssertNil(VMDisplayConfig(argument: "3200x1800px@0").ppi)
    XCTAssertNil(VMDisplayConfig(argument: "3200x1800px@-5").ppi)
  }

  func testEffectivePixelsPerInchIgnoresNonPositiveStoredValue() throws {
    // Defense for a hand-edited config.json: a stored value <= 0 falls back to
    // 72 rather than being handed to VZMacGraphicsDisplayConfiguration.
    XCTAssertEqual(72, VMDisplayConfig(width: 100, height: 100, unit: .pixel, ppi: 0).effectivePixelsPerInch)
    XCTAssertEqual(72, VMDisplayConfig(width: 100, height: 100, unit: .pixel, ppi: -5).effectivePixelsPerInch)
  }
}
