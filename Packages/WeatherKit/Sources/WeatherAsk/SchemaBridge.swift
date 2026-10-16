//
//  SchemaBridge.swift  (WeatherAsk)
//
//  `DayQuery.jsonSchema` read into the on-device model's own schema type, so the
//  model is CONSTRAINED to emit a query the app can decode rather than asked
//  nicely to. A converter and not a second description of the query: the JSON
//  Schema stays the one place the shape is written down (see QueryLanguage.swift),
//  and this only knows the handful of JSON Schema words that file uses — object,
//  array (with minItems/maxItems), string/enum, integer, number, oneOf, const.
//

#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26, iOS 26, visionOS 26, *)
enum SchemaBridge {

    /// The order properties are generated in. The model writes a property's value
    /// before it reads the next property's name, so ORDER IS PROMPT: the
    /// discriminator (`kind`) before its payload, what the day must be like before
    /// which dates, the reduction last. A JSON object has no order of its own.
    private static let order = [
        "kind", "name", "conditions", "measure", "test", "value", "lower", "upper", "band",
        "period", "start", "endExclusive", "scope", "years", "sequence", "precededBy", "within",
        "aggregate", "reduce", "groupBy", "rank", "limit",
    ]

    /// A list with no stated limit gets this one. Unbounded, the model was seen
    /// repeating one condition until it filled its whole context window.
    private static let maximumItems = 4

    /// A TAGGED UNION as one object: `kind` picks the case, and every case's other
    /// fields sit beside it, optional. Offered as separate shapes, the model
    /// mostly took the first one listed — "below 50" came back as "50 or above"
    /// — because it commits to a shape before it has written the word that
    /// decides between them. Here the first thing it writes IS that word. The
    /// result still reads back through the strict decoder, which only looks at
    /// the fields its `kind` uses.
    private static func flattened(_ options: [[String: Any]], _ description: String?) -> [String: Any]? {
        var kinds: [String] = []
        var notes: [String] = []
        var fields: [String: Any] = [:]
        for option in options {
            guard let properties = option["properties"] as? [String: [String: Any]],
                  let kind = properties["kind"]?["const"] as? String else { return nil }
            kinds.append(kind)
            if let note = option["description"] as? String { notes.append("\(kind): \(note)") }
            for (key, value) in properties where key != "kind" { fields[key] = value }
        }
        var kind: [String: Any] = ["type": "string", "enum": kinds]
        if !notes.isEmpty { kind["description"] = notes.joined(separator: " ") }
        fields["kind"] = kind
        var object: [String: Any] = ["type": "object", "properties": fields, "required": ["kind"]]
        if let description { object["description"] = description }
        return object
    }

    static func schema(_ json: [String: Any], name: String) -> DynamicGenerationSchema {
        let description = json["description"] as? String

        if let options = json["oneOf"] as? [[String: Any]], let flat = flattened(options, description) {
            return schema(flat, name: name)
        }
        if let options = json["oneOf"] as? [[String: Any]] {
            return DynamicGenerationSchema(
                name: name, description: description,
                anyOf: options.enumerated().map { index, option in
                    schema(option, name: "\(name)_\(index)")
                })
        }
        if let constant = json["const"] as? String {
            return DynamicGenerationSchema(name: name, description: description, anyOf: [constant])
        }

        switch json["type"] as? String {
        case "object":
            let properties = (json["properties"] as? [String: [String: Any]]) ?? [:]
            let required = Set((json["required"] as? [String]) ?? [])
            let keys = properties.keys.sorted { a, b in
                let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
                return ia == ib ? a < b : ia < ib
            }
            return DynamicGenerationSchema(
                name: name, description: description,
                properties: keys.map { key in
                    let child = properties[key]!
                    return DynamicGenerationSchema.Property(
                        name: key, description: child["description"] as? String,
                        schema: schema(child, name: "\(name)_\(key)"),
                        isOptional: !required.contains(key))
                })
        case "array":
            let items = (json["items"] as? [String: Any]) ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: schema(items, name: "\(name)_item"),
                                           minimumElements: json["minItems"] as? Int,
                                           maximumElements: (json["maxItems"] as? Int) ?? maximumItems)
        case "string":
            if let choices = json["enum"] as? [String] {
                return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
#endif
