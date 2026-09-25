import Foundation

struct HumanReadableByteCount: Encodable, CustomStringConvertible {
  private let byteCount: Int?
  private let jsonValue: any Encodable

  init<JSONValue: Encodable>(_ byteCount: Int?, encodedAs: (Int) -> JSONValue) {
    self.byteCount = byteCount
    self.jsonValue = byteCount.map(encodedAs)
  }

  var description: String {
    guard let byteCount else {
      return "-"
    }

    let formatter = MeasurementFormatter()
    formatter.unitOptions = .naturalScale
    formatter.unitStyle = .medium
    formatter.numberFormatter.maximumFractionDigits = 0

    return formatter.string(
      from: Measurement(value: Double(byteCount), unit: UnitInformationStorage.bytes)
    )
  }

  func encode(to encoder: Encoder) throws {
    try jsonValue.encode(to: encoder)
  }
}
