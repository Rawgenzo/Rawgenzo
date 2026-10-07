import Foundation

/// TIFF 形式(ARW などの RAW の多くは TIFF の構造)のディレクトリ(IFD)を読む最小限の実装。
/// ImageIO では取れないメーカー独自のタグ(Sony のレンズ補正値など)を読むために使う。
/// 壊れたファイルでも落ちないよう、範囲外を読もうとしたら nil を返す。
struct TIFFReader {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// 値そのもの(4 バイト以内)か、値の位置が入っている 4 バイトのファイル内の位置
        let fieldOffset: Int
    }

    private let data: Data
    private let littleEndian: Bool

    /// ファイルは必要な所だけ読まれるよう、メモリに対応付けて開く(RAW 全体は読み込まない)
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        self.data = data
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): littleEndian = true    // "II"
        case (0x4D, 0x4D): littleEndian = false   // "MM"
        default: return nil
        }
        guard u16(at: 2) == 42 else { return nil }
    }

    /// 最初の IFD(IFD0)の位置
    var firstIFDOffset: Int? { u32(at: 4).map(Int.init) }

    /// IFD の項目一覧。タグ番号順に並んでいるとは限らない(ARW の SubIFD は並んでいない)
    func entries(atIFD offset: Int) -> [Entry]? {
        guard let n = u16(at: offset), n > 0, n < 1000 else { return nil }
        var result: [Entry] = []
        for i in 0..<Int(n) {
            let p = offset + 2 + i * 12
            guard let tag = u16(at: p), let type = u16(at: p + 2), let count = u32(at: p + 4) else { return nil }
            result.append(Entry(tag: tag, type: type, count: Int(count), fieldOffset: p + 8))
        }
        return result
    }

    /// 整数として読める型(BYTE, SHORT, LONG とその符号付き、IFD)の値を全部読む
    func integers(_ e: Entry) -> [Int]? {
        let size: Int
        switch e.type {
        case 1, 6: size = 1        // BYTE / SBYTE
        case 3, 8: size = 2        // SHORT / SSHORT
        case 4, 9, 13: size = 4    // LONG / SLONG / IFD
        default: return nil
        }
        guard e.count > 0, e.count < 1_000_000 else { return nil }
        let total = size * e.count
        let start: Int
        if total <= 4 {
            start = e.fieldOffset
        } else {
            guard let p = u32(at: e.fieldOffset) else { return nil }
            start = Int(p)
        }
        guard start >= 0, start + total <= data.count else { return nil }
        var values: [Int] = []
        values.reserveCapacity(e.count)
        for i in 0..<e.count {
            let p = start + i * size
            switch e.type {
            case 1: values.append(Int(data[data.startIndex + p]))
            case 6: values.append(Int(Int8(bitPattern: data[data.startIndex + p])))
            case 3: values.append(Int(u16(at: p)!))
            case 8: values.append(Int(Int16(bitPattern: u16(at: p)!)))
            case 9: values.append(Int(Int32(bitPattern: u32(at: p)!)))
            default: values.append(Int(u32(at: p)!))
            }
        }
        return values
    }

    // MARK: - バイト列

    private func u16(at p: Int) -> UInt16? {
        guard p >= 0, p + 2 <= data.count else { return nil }
        let b0 = UInt16(data[data.startIndex + p]), b1 = UInt16(data[data.startIndex + p + 1])
        return littleEndian ? b0 | b1 << 8 : b0 << 8 | b1
    }

    private func u32(at p: Int) -> UInt32? {
        guard p >= 0, p + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            let b = UInt32(data[data.startIndex + p + i])
            v |= littleEndian ? b << (8 * UInt32(i)) : b << (8 * UInt32(3 - i))
        }
        return v
    }
}
