import Foundation

struct BridgeEnvelope: Equatable {
  var v: Int
  var id: String
  var type: String
  var payload: [String: BridgeJSON]

  func encoded() -> String {
    BridgeJSON.object([
      "v": .number(Double(v)),
      "id": .string(id),
      "type": .string(type),
      "payload": .object(payload),
    ]).canonical()
  }

  static func decode(_ raw: String) -> BridgeEnvelope? {
    guard let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data),
      let object = BridgeJSON(json),
      case .object(let fields) = object,
      case .number(let version) = fields["v"],
      case .string(let id) = fields["id"],
      case .string(let type) = fields["type"],
      case .object(let payload) = fields["payload"]
    else { return nil }
    return BridgeEnvelope(v: Int(version), id: id, type: type, payload: payload)
  }
}

enum BridgeJSON: Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([BridgeJSON])
  case object([String: BridgeJSON])

  init?(_ value: Any) {
    if value is NSNull {
      self = .null
      return
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
      return
    }
    if let string = value as? String {
      self = .string(string)
      return
    }
    if let array = value as? [Any] {
      var decoded: [BridgeJSON] = []
      decoded.reserveCapacity(array.count)
      for item in array {
        guard let value = BridgeJSON(item) else { return nil }
        decoded.append(value)
      }
      self = .array(decoded)
      return
    }
    if let object = value as? [String: Any] {
      var decoded: [String: BridgeJSON] = [:]
      for (key, item) in object {
        guard let value = BridgeJSON(item) else { return nil }
        decoded[key] = value
      }
      self = .object(decoded)
      return
    }
    return nil
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  func canonical() -> String {
    switch self {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      return Self.numberString(value)
    case .string(let value):
      return Self.quoted(value)
    case .array(let values):
      return "[" + values.map { $0.canonical() }.joined(separator: ",") + "]"
    case .object(let fields):
      let body = fields.keys.sorted().map { key in
        Self.quoted(key) + ":" + (fields[key]?.canonical() ?? "null")
      }
      return "{" + body.joined(separator: ",") + "}"
    }
  }

  static func quoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0x00...0x1F:
        out += String(format: "\\u%04x", scalar.value)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
    return out
  }

  private static func numberString(_ value: Double) -> String {
    if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
      return String(Int(value))
    }
    return String(value)
  }
}
