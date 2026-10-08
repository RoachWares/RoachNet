import Foundation

/// Token types stored in `tokenizer.ggml.token_type`.
public enum TokenKind: Int32 {
    case undefined = 0
    case normal = 1
    case unknown = 2
    case control = 3
    case userDefined = 4
    case unused = 5
    case byte = 6
}

/// Native tokenizer for GGUF vocabularies: SentencePiece-style (`llama`) and
/// byte-level BPE (`gpt2`). Behaviour matches the reference tokenizers token for token.
public final class Tokenizer {
    public enum Model: String {
        case sentencePiece = "llama"
        case bytePairEncoding = "gpt2"
    }

    public let model: Model
    public let tokens: [String]
    public let kinds: [TokenKind]
    public let scores: [Float]
    public let bos: Int32?
    public let eos: Int32?
    public let endOfGeneration: Set<Int32>
    public let addBOS: Bool
    public let addEOS: Bool
    public let addSpacePrefix: Bool
    public let preTokenizer: String

    let tokenIds: [String: Int32]
    let mergeRanks: [String: Int]
    let ignoreMerges: Bool
    let splitPatterns: [NSRegularExpression]
    let specialTokens: [Int32]
    let byteEncoder: [Character]
    let byteDecoder: [Character: UInt8]

    public var vocabularySize: Int { tokens.count }

    public init(gguf: GGUFFile) throws {
        guard let modelName = gguf["tokenizer.ggml.model"]?.stringValue else { throw InferenceError.missingKey("tokenizer.ggml.model") }
        guard let model = Model(rawValue: modelName) else { throw InferenceError.invalid("Tokenizer \(modelName) is not supported yet.") }
        self.model = model
        guard let tokenValues = gguf["tokenizer.ggml.tokens"]?.arrayValue else { throw InferenceError.missingKey("tokenizer.ggml.tokens") }
        let tokens = tokenValues.map { $0.stringValue ?? "" }
        self.tokens = tokens
        let count = tokens.count
        self.scores = gguf["tokenizer.ggml.scores"]?.arrayValue?.map { Float($0.doubleValue ?? 0) } ?? Array(repeating: 0, count: count)
        var kinds = gguf["tokenizer.ggml.token_type"]?.arrayValue?.map { TokenKind(rawValue: Int32($0.intValue ?? 1)) ?? .normal }
            ?? Array(repeating: .normal, count: count)
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(count)
        for (index, token) in tokens.enumerated() where ids[token] == nil {
            ids[token] = Int32(index)
        }
        self.tokenIds = ids

        var ranks: [String: Int] = [:]
        if let merges = gguf["tokenizer.ggml.merges"]?.arrayValue {
            ranks.reserveCapacity(merges.count)
            for (rank, merge) in merges.enumerated() {
                if let text = merge.stringValue, ranks[text] == nil { ranks[text] = rank }
            }
        }
        self.mergeRanks = ranks

        func tokenId(_ key: String) -> Int32? {
            guard let value = gguf[key]?.intValue, value >= 0, value < count else { return nil }
            return Int32(value)
        }
        self.bos = tokenId("tokenizer.ggml.bos_token_id")
        self.eos = tokenId("tokenizer.ggml.eos_token_id")

        let pre = gguf["tokenizer.ggml.pre"]?.stringValue ?? "default"
        self.preTokenizer = pre
        var addBOS: Bool
        var addSpacePrefix: Bool
        var ignoreMerges = false
        switch model {
        case .sentencePiece:
            addBOS = true
            addSpacePrefix = true
            self.splitPatterns = []
        case .bytePairEncoding:
            addBOS = false
            addSpacePrefix = false
            let (patterns, ignores, forcesBOS) = Tokenizer.preTokenizerRules(pre)
            ignoreMerges = ignores
            if forcesBOS { addBOS = true }
            self.splitPatterns = try patterns.map { try NSRegularExpression(pattern: $0, options: []) }
        }
        if let explicit = gguf["tokenizer.ggml.add_bos_token"]?.boolValue { addBOS = explicit }
        if let explicit = gguf["tokenizer.ggml.add_space_prefix"]?.boolValue { addSpacePrefix = explicit }
        self.addBOS = addBOS && bos != nil
        self.addEOS = (gguf["tokenizer.ggml.add_eos_token"]?.boolValue ?? false) && eos != nil
        self.addSpacePrefix = addSpacePrefix
        self.ignoreMerges = ignoreMerges

        // End-of-generation tokens: EOS/EOT/EOM plus well-known turn terminators.
        var eog = Set<Int32>()
        if let eos { eog.insert(eos) }
        for key in ["tokenizer.ggml.eot_token_id", "tokenizer.ggml.eom_token_id"] {
            if let id = tokenId(key) { eog.insert(id) }
        }
        let terminators: Set<String> = [
            "<|eot_id|>", "<|im_end|>", "<|end|>", "<|return|>", "<|call|>", "<end_of_turn>", "<|endoftext|>",
            "<|eom_id|>", "<EOT>", "_<EOT>", "<|end_of_text|>", "<end_of_utterance>", "<eos>", "<turn|>",
            "<｜end▁of▁sentence｜>",
        ]
        for terminator in terminators {
            if let id = ids[terminator] {
                eog.insert(id)
                if kinds[Int(id)] != .control { kinds[Int(id)] = .control }
            }
        }
        self.endOfGeneration = eog
        self.kinds = kinds

        self.specialTokens = (0..<count)
            .filter { [.control, .userDefined, .unknown].contains(kinds[$0]) && !tokens[$0].isEmpty }
            .sorted { tokens[$0].utf8.count > tokens[$1].utf8.count }
            .map { Int32($0) }

        let (encoder, decoder) = Tokenizer.byteLevelTables()
        self.byteEncoder = encoder
        self.byteDecoder = decoder
    }

    /// Pre-tokenizer split patterns (applied in sequence), whether whole-word
    /// vocabulary hits skip merging, and whether BOS is forced on.
    static func preTokenizerRules(_ name: String) -> ([String], Bool, Bool) {
        let gpt2 = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)"
        let llama3 = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let qwen2 = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let qwen35 = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let tekken = "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]*[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]+|[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]*|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n/]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let gpt4o = "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]*[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n/]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        switch name {
        case "llama3", "llama-v3", "llama-bpe", "falcon3", "pixtral", "lfm2":
            return ([llama3], true, true)
        case "dbrx", "smaug-bpe", "chatglm-bpe":
            return ([llama3], false, false)
        case "qwen2", "deepseek-r1-qwen", "megrez", "stablelm2", "hunyuan":
            return ([qwen2], false, false)
        case "qwen35":
            return ([qwen35], false, false)
        case "smollm", "starcoder", "refact", "command-r", "codeshell", "exaone", "minerva-7b":
            return (["\\p{N}", gpt2], false, false)
        case "gpt-2", "phi-2", "mpt", "olmo", "jais", "exaone4", "roberta-bpe":
            return ([gpt2], false, false)
        case "tekken":
            return ([tekken], true, true)
        case "gpt-4o", "llama4":
            return ([gpt4o], false, false)
        case "deepseek-coder":
            return (["[\\r\\n]", "\\s?\\p{L}+", "\\s?\\p{P}+", "[一-龥ࠀ-一가-퟿]+", "\\p{N}"], false, false)
        default:
            return (["[\\p{P}\\$\\+<=>\\^~\\|]+", gpt2, "\\p{N}+", "[0-9][0-9][0-9]"], false, false)
        }
    }

    /// GPT-2 byte-to-unicode mapping used by byte-level BPE vocabularies.
    static func byteLevelTables() -> ([Character], [Character: UInt8]) {
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = printable
        var extra = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            codepoints.append(256 + extra)
            extra += 1
        }
        var encoder = [Character](repeating: " ", count: 256)
        var decoder: [Character: UInt8] = [:]
        for (byte, codepoint) in zip(printable, codepoints) {
            let character = Character(Unicode.Scalar(UInt32(codepoint))!)
            encoder[byte] = character
            decoder[character] = UInt8(byte)
        }
        return (encoder, decoder)
    }

    public func id(of text: String) -> Int32? { tokenIds[text] }

    public func isEndOfGeneration(_ token: Int32) -> Bool { endOfGeneration.contains(token) }

    // MARK: Encoding

    enum Fragment {
        case text(String)
        case token(Int32)
    }

    /// Splits out special tokens (longest first). Control and unknown tokens are
    /// only recognised when `parseSpecial` is set; user-defined ones always are.
    func partition(_ text: String, parseSpecial: Bool) -> [Fragment] {
        guard !text.isEmpty else { return [] }
        var fragments: [Fragment] = [.text(text)]
        for special in specialTokens {
            let kind = kinds[Int(special)]
            if !parseSpecial && (kind == .control || kind == .unknown) { continue }
            let needle = tokens[Int(special)]
            var next: [Fragment] = []
            next.reserveCapacity(fragments.count)
            for fragment in fragments {
                guard case .text(let raw) = fragment, raw.contains(needle) else {
                    next.append(fragment)
                    continue
                }
                var rest = Substring(raw)
                while let range = rest.range(of: needle) {
                    if range.lowerBound > rest.startIndex { next.append(.text(String(rest[rest.startIndex..<range.lowerBound]))) }
                    next.append(.token(special))
                    rest = rest[range.upperBound...]
                }
                if !rest.isEmpty { next.append(.text(String(rest))) }
            }
            fragments = next
        }
        return fragments
    }

    /// Encodes `text` to token ids. `addSpecial` adds BOS/EOS as the model
    /// requests; `parseSpecial` turns control-token text into control tokens.
    public func encode(_ text: String, addSpecial: Bool = true, parseSpecial: Bool = true) -> [Int32] {
        var output: [Int32] = []
        let fragments = partition(text, parseSpecial: parseSpecial)
        if addSpecial && addBOS, let bos { output.append(bos) }
        switch model {
        case .sentencePiece:
            var previousWasSpecial = true
            for fragment in fragments {
                switch fragment {
                case .token(let id):
                    output.append(id)
                    previousWasSpecial = true
                case .text(let raw):
                    var text = raw
                    if addSpacePrefix && previousWasSpecial { text = " " + text }
                    encodeSentencePiece(text.replacingOccurrences(of: " ", with: "\u{2581}"), into: &output)
                    previousWasSpecial = false
                }
            }
        case .bytePairEncoding:
            for fragment in fragments {
                switch fragment {
                case .token(let id): output.append(id)
                case .text(let raw): encodeBytePairs(raw, into: &output)
                }
            }
        }
        if addSpecial && addEOS, let eos { output.append(eos) }
        return output
    }

    // SentencePiece-style: greedy highest-score bigram merges over UTF-8
    // characters, then byte fallback for anything outside the vocabulary.
    private func encodeSentencePiece(_ text: String, into output: inout [Int32]) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        struct Symbol { var start: Int; var length: Int; var prev: Int; var next: Int }
        var symbols: [Symbol] = []
        var offset = 0
        while offset < bytes.count {
            let length = min(Tokenizer.utf8Length(bytes[offset]), bytes.count - offset)
            symbols.append(Symbol(start: offset, length: length, prev: symbols.count - 1, next: offset + length == bytes.count ? -1 : symbols.count + 1))
            offset += length
        }
        struct Bigram { let left: Int; let right: Int; let score: Float; let size: Int }
        var queue = BinaryHeap<Bigram> { a, b in a.score > b.score || (a.score == b.score && a.left < b.left) }
        var reverseMerges: [String: (Int, Int)] = [:]
        func slice(_ start: Int, _ length: Int) -> String { String(decoding: bytes[start..<(start + length)], as: UTF8.self) }
        func tryAddBigram(_ left: Int, _ right: Int) {
            guard left >= 0, right >= 0 else { return }
            let piece = slice(symbols[left].start, symbols[left].length + symbols[right].length)
            guard let id = tokenIds[piece] else { return }
            queue.push(Bigram(left: left, right: right, score: scores[Int(id)], size: piece.utf8.count))
            reverseMerges[piece] = (left, right)
        }
        for index in 1..<symbols.count { tryAddBigram(index - 1, index) }
        while let bigram = queue.pop() {
            let left = symbols[bigram.left], right = symbols[bigram.right]
            if left.length == 0 || right.length == 0 || left.length + right.length != bigram.size { continue }
            symbols[bigram.left].length += right.length
            symbols[bigram.right].length = 0
            symbols[bigram.left].next = right.next
            if right.next >= 0 { symbols[right.next].prev = bigram.left }
            tryAddBigram(symbols[bigram.left].prev, bigram.left)
            tryAddBigram(bigram.left, symbols[bigram.left].next)
        }
        func resegment(_ index: Int) {
            let symbol = symbols[index]
            let piece = slice(symbol.start, symbol.length)
            if let id = tokenIds[piece] {
                output.append(id)
                return
            }
            if let (left, right) = reverseMerges[piece] {
                resegment(left)
                resegment(right)
                return
            }
            for byte in bytes[symbol.start..<(symbol.start + symbol.length)] {
                if let id = tokenIds[String(format: "<0x%02X>", byte)] {
                    output.append(id)
                } else if let id = tokenIds[String(decoding: [byte], as: UTF8.self)] {
                    output.append(id)
                }
            }
        }
        var index = 0
        while index != -1 {
            resegment(index)
            index = symbols[index].next
        }
    }

    /// Splits `text` with each pattern in turn; unmatched gaps stay as pieces.
    func preTokenize(_ text: String) -> [String] {
        var pieces = [text]
        for pattern in splitPatterns {
            var next: [String] = []
            for piece in pieces {
                let ns = piece as NSString
                var cursor = 0
                for match in pattern.matches(in: piece, options: [], range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
                    if match.range.location > cursor {
                        next.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                    }
                    next.append(ns.substring(with: match.range))
                    cursor = match.range.location + match.range.length
                }
                if cursor < ns.length { next.append(ns.substring(from: cursor)) }
            }
            pieces = next
        }
        return pieces
    }

    // Byte-level BPE: each pre-tokenized word becomes byte characters, then
    // pairs merge lowest merge-rank first.
    private func encodeBytePairs(_ text: String, into output: inout [Int32]) {
        for word in preTokenize(text) {
            let encoded = String(word.utf8.map { byteEncoder[Int($0)] })
            if ignoreMerges, let id = tokenIds[encoded] {
                output.append(id)
                continue
            }
            var symbols = encoded.map { String($0) }
            if symbols.count > 1 {
                var alive = [Bool](repeating: true, count: symbols.count)
                var prev = Array(-1..<(symbols.count - 1))
                var next = Array(1...symbols.count)
                next[symbols.count - 1] = -1
                struct Pair { let left: Int; let right: Int; let rank: Int; let text: String }
                var queue = BinaryHeap<Pair> { a, b in a.rank < b.rank || (a.rank == b.rank && a.left < b.left) }
                func addPair(_ left: Int, _ right: Int) {
                    guard left >= 0, right >= 0, let rank = mergeRanks[symbols[left] + " " + symbols[right]] else { return }
                    queue.push(Pair(left: left, right: right, rank: rank, text: symbols[left] + symbols[right]))
                }
                for index in 1..<symbols.count { addPair(index - 1, index) }
                while let pair = queue.pop() {
                    guard alive[pair.left], alive[pair.right], symbols[pair.left] + symbols[pair.right] == pair.text,
                          next[pair.left] == pair.right else { continue }
                    symbols[pair.left] = pair.text
                    alive[pair.right] = false
                    next[pair.left] = next[pair.right]
                    if next[pair.right] >= 0 { prev[next[pair.right]] = pair.left }
                    addPair(prev[pair.left], pair.left)
                    addPair(pair.left, next[pair.left])
                }
                symbols = symbols.indices.filter { alive[$0] }.map { symbols[$0] }
            }
            for symbol in symbols {
                if let id = tokenIds[symbol] {
                    output.append(id)
                } else {
                    for character in symbol {
                        if let id = tokenIds[String(character)] { output.append(id) }
                    }
                }
            }
        }
    }

    static func utf8Length(_ lead: UInt8) -> Int {
        switch lead >> 4 {
        case 0xF: return 4
        case 0xE: return 3
        case 0xC, 0xD: return 2
        default: return 1
        }
    }

    // MARK: Decoding

    /// Raw bytes for one token. Control and unknown tokens render only when `special` is set.
    public func piece(_ token: Int32, special: Bool = false) -> [UInt8] {
        guard token >= 0, Int(token) < tokens.count else { return [] }
        let text = tokens[Int(token)]
        let kind = kinds[Int(token)]
        switch kind {
        case .control, .unknown:
            return special ? Array(text.utf8) : []
        case .userDefined:
            return Array(text.utf8)
        case .byte:
            if text.hasPrefix("<0x"), text.hasSuffix(">"), let value = UInt8(text.dropFirst(3).dropLast(), radix: 16) {
                return [value]
            }
            return Array(text.utf8)
        case .normal:
            switch model {
            case .sentencePiece:
                return Array(text.replacingOccurrences(of: "\u{2581}", with: " ").utf8)
            case .bytePairEncoding:
                return text.compactMap { byteDecoder[$0] }
            }
        case .unused, .undefined:
            return []
        }
    }

    public func decode(_ ids: [Int32], special: Bool = false) -> String {
        String(decoding: ids.flatMap { piece($0, special: special) }, as: UTF8.self)
    }
}

/// Incremental UTF-8 assembly for streamed tokens: holds back an incomplete
/// multi-byte sequence until the bytes that finish it arrive.
public struct StreamingDecoder {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        var end = pending.count
        // Find the start of a trailing, possibly incomplete sequence.
        var index = pending.count - 1
        var continuation = 0
        while index >= 0, pending[index] & 0xC0 == 0x80, continuation < 3 {
            continuation += 1
            index -= 1
        }
        if index >= 0 {
            let needed = Tokenizer.utf8Length(pending[index])
            if needed > 1, pending.count - index < needed { end = index }
        }
        let ready = Array(pending[..<end])
        pending = Array(pending[end...])
        return String(decoding: ready, as: UTF8.self)
    }

    public mutating func flush() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Minimal binary heap; `ordered(a, b)` is true when `a` should pop first.
struct BinaryHeap<Element> {
    private var storage: [Element] = []
    private let ordered: (Element, Element) -> Bool

    init(_ ordered: @escaping (Element, Element) -> Bool) {
        self.ordered = ordered
    }

    var isEmpty: Bool { storage.isEmpty }
    var storageFirst: Element? { storage.first }

    mutating func push(_ element: Element) {
        storage.append(element)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard ordered(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let top = storage.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var best = parent
            if left < storage.count, ordered(storage[left], storage[best]) { best = left }
            if right < storage.count, ordered(storage[right], storage[best]) { best = right }
            if best == parent { break }
            storage.swapAt(parent, best)
            parent = best
        }
        return top
    }
}
