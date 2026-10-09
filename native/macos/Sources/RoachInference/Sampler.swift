import Foundation

/// Token sampling settings (Ollama option names in comments).
public struct SamplingOptions: Equatable {
    public var temperature: Float = 0.8          // temperature; 0 = greedy
    public var topK: Int = 40                    // top_k; 0 = off
    public var topP: Float = 0.9                 // top_p; 1 = off
    public var minP: Float = 0.0                 // min_p; 0 = off
    public var repeatPenalty: Float = 1.1        // repeat_penalty; 1 = off
    public var repeatLastN: Int = 64             // repeat_last_n
    public var presencePenalty: Float = 0        // presence_penalty
    public var frequencyPenalty: Float = 0       // frequency_penalty
    public var seed: UInt64? = nil               // seed

    public init() {}

    public static var greedy: SamplingOptions {
        var options = SamplingOptions()
        options.temperature = 0
        options.repeatPenalty = 1
        return options
    }
}

/// SplitMix64: small, fast, and reproducible across platforms.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct Sampler {
    public var options: SamplingOptions
    private var generator: SeededGenerator

    public init(options: SamplingOptions) {
        self.options = options
        generator = SeededGenerator(seed: options.seed ?? UInt64.random(in: .min ... .max))
    }

    /// Chain: penalties → top-k → top-p → min-p → temperature → draw.
    public mutating func sample(_ logits: [Float], history: [Int32]) -> Int32 {
        var logits = logits
        applyPenalties(&logits, history: history)
        if options.temperature <= 0 {
            var best = 0
            for i in 1..<logits.count where logits[i] > logits[best] { best = i }
            return Int32(best)
        }
        var candidates: [(id: Int32, logit: Float)]
        if options.topK > 0, options.topK < logits.count {
            candidates = Sampler.topK(logits, options.topK)
        } else {
            candidates = logits.indices.map { (id: Int32($0), logit: logits[$0]) }
            candidates.sort { $0.logit > $1.logit || ($0.logit == $1.logit && $0.id < $1.id) }
        }
        // Probabilities at temperature 1 for the nucleus/min-p filters.
        func softmax(_ items: [(id: Int32, logit: Float)], temperature: Float) -> [Float] {
            let maximum = items.first?.logit ?? 0
            var weights = items.map { expf(($0.logit - maximum) / temperature) }
            let total = weights.reduce(0, +)
            for i in weights.indices { weights[i] /= total }
            return weights
        }
        if options.topP < 1 {
            let probabilities = softmax(candidates, temperature: 1)
            var cumulative: Float = 0
            var keep = candidates.count
            for (index, p) in probabilities.enumerated() {
                cumulative += p
                if cumulative >= options.topP { keep = index + 1; break }
            }
            candidates = Array(candidates.prefix(max(1, keep)))
        }
        if options.minP > 0 {
            let probabilities = softmax(candidates, temperature: 1)
            let threshold = (probabilities.first ?? 0) * options.minP
            let filtered = candidates.indices.filter { probabilities[$0] >= threshold }.map { candidates[$0] }
            if !filtered.isEmpty { candidates = filtered }
        }
        let weights = softmax(candidates, temperature: options.temperature)
        var draw = Float(Double(generator.next() >> 11) / Double(1 << 53))
        for (index, weight) in weights.enumerated() {
            draw -= weight
            if draw <= 0 { return candidates[index].id }
        }
        return candidates.last?.id ?? 0
    }

    /// The k largest logits, best first (ties: lower id first). One pass over
    /// the vocabulary with a k-slot buffer; after warm-up almost every logit is
    /// rejected by a single comparison, so no per-token array of tuples is built.
    static func topK(_ logits: [Float], _ k: Int) -> [(id: Int32, logit: Float)] {
        var ids = [Int32](repeating: 0, count: k)
        var values = [Float](repeating: -.infinity, count: k)
        var filled = 0, minIndex = 0
        var minValue = -Float.infinity
        func refreshMinimum() {
            minIndex = 0
            for slot in 1..<k where values[slot] < values[minIndex] || (values[slot] == values[minIndex] && ids[slot] > ids[minIndex]) { minIndex = slot }
            minValue = values[minIndex]
        }
        logits.withUnsafeBufferPointer { buffer in
            for index in 0..<buffer.count {
                let value = buffer[index]
                if filled < k {
                    ids[filled] = Int32(index); values[filled] = value; filled += 1
                    if filled == k { refreshMinimum() }
                } else if value > minValue {
                    ids[minIndex] = Int32(index); values[minIndex] = value
                    refreshMinimum()
                }
            }
        }
        var result = (0..<filled).map { (id: ids[$0], logit: values[$0]) }
        result.sort { $0.logit > $1.logit || ($0.logit == $1.logit && $0.id < $1.id) }
        return result
    }

    func applyPenalties(_ logits: inout [Float], history: [Int32]) {
        let window = options.repeatLastN < 0 ? history.count : min(options.repeatLastN, history.count)
        guard window > 0 else { return }
        let hasRepeat = options.repeatPenalty != 1
        let hasPresence = options.presencePenalty != 0 || options.frequencyPenalty != 0
        guard hasRepeat || hasPresence else { return }
        var counts: [Int32: Int] = [:]
        for token in history.suffix(window) { counts[token, default: 0] += 1 }
        for (token, count) in counts where Int(token) < logits.count {
            var value = logits[Int(token)]
            if hasRepeat { value = value > 0 ? value / options.repeatPenalty : value * options.repeatPenalty }
            value -= Float(count) * options.frequencyPenalty + options.presencePenalty
            logits[Int(token)] = value
        }
    }
}

extension Array {
    /// The `limit` best elements by `areInIncreasingOrder`, sorted.
    func partialSorted(by areInIncreasingOrder: @escaping (Element, Element) -> Bool, limit: Int) -> ArraySlice<Element> {
        guard limit < count else { return sorted(by: areInIncreasingOrder)[...] }
        // Keep the current best `limit` in a heap with the worst on top.
        var heap = BinaryHeap<Element> { a, b in areInIncreasingOrder(b, a) }
        var size = 0
        for element in self {
            if size < limit {
                heap.push(element)
                size += 1
            } else if let worst = heap.storageFirst, areInIncreasingOrder(element, worst) {
                _ = heap.pop()
                heap.push(element)
            }
        }
        var result: [Element] = []
        result.reserveCapacity(limit)
        while let element = heap.pop() { result.append(element) }
        return result.reversed()[...]
    }
}
