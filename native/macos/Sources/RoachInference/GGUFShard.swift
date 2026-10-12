import Foundation

/// Writes the part of a GGUF model that one RoachNet Cluster stage needs: the
/// metadata byte for byte (tokenizer and all), a `roachnet.stage` key naming
/// the stage, and only that stage's tensors. The result is an ordinary GGUF
/// file that `TransformerModel` opens as that stage.
public enum GGUFShard {
    public static let stageKey = "roachnet.stage"

    /// Bytes the shard will take, without writing it.
    public static func size(of file: GGUFFile, stage: ModelStage) -> Int {
        layout(file, stage).total
    }

    @discardableResult
    public static func write(_ file: GGUFFile, stage: ModelStage, to path: String) throws -> Int {
        guard file.metadata[stageKey] == nil else { throw InferenceError.invalid("A shard can only be cut from a whole model file.") }
        let plan = layout(file, stage)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { throw InferenceError.cannotOpen(path) }
        defer { try? handle.close() }
        try handle.write(contentsOf: plan.header)
        var written = plan.header.count
        for (info, offset) in plan.tensors {
            let start = plan.header.count + offset
            if start > written {
                try handle.write(contentsOf: Data(count: start - written))
                written = start
            }
            // Large tensors go out in pieces straight from the mapped file.
            let source = file.pointer(to: info)
            var done = 0
            while done < info.byteCount {
                let piece = min(8 << 20, info.byteCount - done)
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: source + done), count: piece, deallocator: .none))
                done += piece
            }
            written += info.byteCount
        }
        return written
    }

    private struct Layout {
        var header: Data
        var tensors: [(GGUFTensorInfo, Int)]
        var total: Int
    }

    private static func layout(_ file: GGUFFile, _ stage: ModelStage) -> Layout {
        let tied = file.tensors["output.weight"] == nil
        let chosen = file.tensorNames.compactMap { file.tensors[$0] }.filter { stage.includes(tensor: $0.name, tiedOutput: tied) }
        var header = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func string(_ text: String) {
            let bytes = Array(text.utf8)
            u64(UInt64(bytes.count))
            header.append(contentsOf: bytes)
        }
        // Magic and version, then the counts, then the source's metadata unchanged.
        header.append(Data(bytes: file.base, count: 8))
        u64(UInt64(chosen.count))
        u64(UInt64(file.metadataCount + 1))
        header.append(Data(bytes: file.base + 24, count: file.metadataEnd - 24))
        string(stageKey)
        u32(8)
        string(stage.description)

        var offsets: [(GGUFTensorInfo, Int)] = []
        var offset = 0
        for info in chosen {
            offset = (offset + file.alignment - 1) / file.alignment * file.alignment
            offsets.append((info, offset))
            offset += info.byteCount
        }
        for (info, start) in offsets {
            string(info.name)
            u32(UInt32(info.shape.count))
            for dimension in info.shape { u64(UInt64(dimension)) }
            u32(info.type.rawValue)
            u64(UInt64(start))
        }
        let padded = (header.count + file.alignment - 1) / file.alignment * file.alignment
        header.append(Data(count: padded - header.count))
        return Layout(header: header, tensors: offsets, total: header.count + offset)
    }
}
