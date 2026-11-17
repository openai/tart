import ArgumentParser

func validateLocalName(_ name: String, argument: String = "<name>") throws {
  if name.contains("/") {
    throw ValidationError("\(argument) should be a local name")
  }
}

func validateGreaterThanZero<T: BinaryInteger>(_ value: T?, option: String) throws {
  if let value = value, value <= 0 {
    throw ValidationError("--\(option) must be greater than zero")
  }
}
