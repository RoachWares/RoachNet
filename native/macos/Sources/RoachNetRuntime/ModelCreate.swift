import Foundation
import RoachInference

enum Modelfile {
    struct Parsed {
        var from: String?
        var system: String?
        var template: String?
        var parameters = JSONObject()
        var messages: [JSON] = []
    }

    static func parse(_ text: String) throws -> Parsed {
        var parsed = Parsed()
        var rest = Substring(text)
        func skipBlanks() { rest = rest.drop { $0 == " " || $0 == "\t" } }
        func word() -> String {
            skipBlanks()
            let value = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(value.count)
            return String(value)
        }
        func value() throws -> String {
            skipBlanks()
            if rest.hasPrefix("\"\"\"") {
                rest = rest.dropFirst(3)
                guard let end = rest.range(of: "\"\"\"") else {
                    throw requestError("A \"\"\" block in the Modelfile is never closed.", 400)
                }
                let inside = String(rest[..<end.lowerBound])
                rest = rest[end.upperBound...]
                return inside
            }
            let line = rest.prefix { $0 != "\n" }
            rest = rest.dropFirst(line.count)
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                text = (try? JSON.parse(text))?.stringValue ?? String(text.dropFirst().dropLast())
            }
            return text
        }
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { break }
            if rest.hasPrefix("#") {
                rest = rest.drop { $0 != "\n" }
                continue
            }
            let command = word().uppercased()
            switch command {
            case "FROM": parsed.from = try value()
            case "SYSTEM": parsed.system = try value()
            case "TEMPLATE": parsed.template = try value()
            case "PARAMETER":
                let key = word().lowercased()
                let raw = try value()
                if key == "stop" {
                    parsed.parameters["stop"] = .array(parsed.parameters["stop"].array + [JSON(raw)])
                } else if let number = Double(raw) {
                    parsed.parameters[key] = JSON(number)
                } else if raw == "true" || raw == "false" {
                    parsed.parameters[key] = JSON(raw == "true")
                } else {
                    parsed.parameters[key] = JSON(raw)
                }
            case "MESSAGE":
                let role = word().lowercased()
                guard ["system", "user", "assistant"].contains(role) else {
                    throw requestError("MESSAGE needs a role of system, user or assistant.", 400)
                }
                parsed.messages.append(["role": JSON(role), "content": JSON(try value())])
            case "LICENSE", "REQUIRES":
                _ = try value()
            case "ADAPTER":
                throw requestError("LoRA adapters aren't supported by the native engine yet.", 400)
            default:
                throw requestError("The Modelfile has an unknown command, \(command).", 400)
            }
        }
        return parsed
    }

    static func text(for entry: NativeModelStore.Entry) -> (modelfile: String, parameters: String, system: String) {
        let profile = entry.manifest["profile"]
        var lines = ["# RoachNet native model", "FROM \(entry.manifest["derivedFrom"].stringValue ?? entry.name)"]
        let system = profile["system"].stringValue ?? ""
        if !system.isEmpty { lines.append("SYSTEM \"\"\"\(system)\"\"\"") }
        var parameters: [String] = []
        for (key, value) in profile["parameters"].object {
            if key == "stop" {
                for stop in value.array { parameters.append("\(key) \(stop.serialized())") }
            } else {
                parameters.append("\(key) \(value.stringValue ?? value.serialized())")
            }
        }
        lines += parameters.map { "PARAMETER \($0)" }
        for message in profile["messages"].array {
            lines.append(
                "MESSAGE \(message["role"].stringValue ?? "user") \"\"\"\(message["content"].stringValue ?? "")\"\"\"")
        }
        return (lines.joined(separator: "\n") + "\n", parameters.joined(separator: "\n"), system)
    }
}

extension NativeModelServer {
    func createModel(_ body: JSON) throws -> HTTPResponse {
        let name = body["model"].stringValue ?? body["name"].stringValue ?? ""
        _ = try NativeModelStore.normalize(name)
        var from = body["from"].stringValue
        var system = body["system"].stringValue
        var parameters = body["parameters"].object
        var messages = body["messages"].array
        var template = body["template"].stringValue
        if let source = body["modelfile"].stringValue {
            let parsed = try Modelfile.parse(source)
            from = from ?? parsed.from
            system = system ?? parsed.system
            template = template ?? parsed.template
            for (key, value) in parsed.parameters where parameters[key].isUndefined { parameters[key] = value }
            if messages.isEmpty { messages = parsed.messages }
        }
        if !body["quantize"].isUndefined {
            throw requestError("Re-quantizing isn't supported yet; pull the quantization you want instead.", 400)
        }
        if !body["adapters"].object.isEmpty || !body["adapters"].array.isEmpty {
            throw requestError("LoRA adapters aren't supported by the native engine yet.", 400)
        }
        guard let from, !from.isEmpty else {
            if !body["files"].isUndefined {
                throw requestError(
                    "Uploaded model files aren't accepted; use FROM with an installed model or the path of a .gguf file on this Mac.",
                    400)
            }
            throw requestError("Name the model to build on with `from` (or FROM in a Modelfile).", 400)
        }
        var profile = JSONObject()
        if let system { profile["system"] = JSON(system) }
        if !parameters.isEmpty { profile["parameters"] = .object(parameters) }
        if !messages.isEmpty {
            profile["messages"] = .array(
                messages.map { ["role": $0["role"] || "user", "content": JSON(ModelRequest.text($0["content"]))] })
        }
        if let template, !template.isEmpty { profile["template"] = JSON(template) }

        let path = (from as NSString).expandingTildeInPath
        let fromFile = from.hasPrefix("/") || from.hasPrefix("~") || from.hasPrefix(".")
        if fromFile {
            guard path.hasPrefix("/"), path.lowercased().hasSuffix(".gguf"), Files.exists(path) else {
                throw requestError("\(from) isn't a .gguf file on this Mac; give its full path.", 400)
            }
        } else if store.entry(from) == nil {
            throw requestError("model '\(from)' not found, try pulling it first", 404)
        }
        let store = self.store
        let work: ((String) -> Void) throws -> Void = { status in
            if fromFile {
                status("copying model file")
                let entry = try store.importFile(path, as: name)
                if !profile.isEmpty { _ = try store.setProfile(entry, .object(profile)) }
            } else {
                status("using existing layers")
                guard let base = store.entry(from) else { throw requestError("model '\(from)' not found", 404) }
                _ = try store.createDerived(name, from: base, profile: .object(profile))
            }
            status("writing manifest")
        }
        unload((try? NativeModelStore.normalize(name).name) ?? name)
        let stream = body["stream"].isUndefined ? true : body["stream"].truthy
        if !stream {
            try work { _ in }
            return .json(200, ["status": "success"])
        }
        return .ndjsonStream { [self] writer in
            do {
                try work { status in writer.write(self.line(["status": JSON(status)])) }
                writer.write(self.line(["status": "success"]))
            } catch {
                writer.write(self.line(["error": JSON((error as? RuntimeError)?.message ?? "\(error)")]))
            }
        }
    }
}
