/// Line-based three-way merge for note bodies (architecture §7, `body`).
///
/// Lines of the base that both sides kept unchanged are anchors; between two
/// anchors, a hunk changed on one side only takes that side, a hunk changed
/// identically on both takes either, and a hunk changed differently on both
/// sides is a conflict (the caller offers Keep Both).
enum Diff3 {
    /// Largest `base × side` line product diffed with the LCS table; beyond
    /// it the whole text is one hunk (conflict unless one side is unchanged).
    static let maxCells = 4_000_000

    /// The merged text, or `nil` on overlapping changes.
    static func merge(base: String, apple: String, markdown: String) -> String? {
        if apple == markdown { return apple }
        if apple == base { return markdown }
        if markdown == base { return apple }
        let lines = { (text: String) in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        return merge(base: lines(base), apple: lines(apple), markdown: lines(markdown))?.joined(separator: "\n")
    }

    static func merge(base: [String], apple: [String], markdown: [String]) -> [String]? {
        let toApple = Dictionary(lcs(base, apple), uniquingKeysWith: { first, _ in first })
        let toMarkdown = Dictionary(lcs(base, markdown), uniquingKeysWith: { first, _ in first })
        var result: [String] = []
        var (baseStart, appleStart, markdownStart) = (0, 0, 0)
        for index in base.indices {
            guard let appleIndex = toApple[index], let markdownIndex = toMarkdown[index] else { continue }
            guard
                let hunk = resolve(
                    base[baseStart..<index], apple[appleStart..<appleIndex], markdown[markdownStart..<markdownIndex])
            else { return nil }
            result += hunk
            result.append(base[index])
            (baseStart, appleStart, markdownStart) = (index + 1, appleIndex + 1, markdownIndex + 1)
        }
        guard
            let tail = resolve(
                base[baseStart...], apple[appleStart...], markdown[markdownStart...])
        else { return nil }
        return result + tail
    }

    private static func resolve(
        _ base: ArraySlice<String>, _ apple: ArraySlice<String>, _ markdown: ArraySlice<String>
    ) -> [String]? {
        if apple.elementsEqual(markdown) { return Array(apple) }
        if apple.elementsEqual(base) { return Array(markdown) }
        if markdown.elementsEqual(base) { return Array(apple) }
        return nil
    }

    /// Longest common subsequence as (index in `left`, index in `right`) pairs.
    static func lcs(_ left: [String], _ right: [String]) -> [(Int, Int)] {
        let (rows, columns) = (left.count, right.count)
        guard rows > 0, columns > 0, rows * columns <= maxCells else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                table[row][column] =
                    left[row] == right[column]
                    ? table[row + 1][column + 1] + 1 : max(table[row + 1][column], table[row][column + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var (row, column) = (0, 0)
        while row < rows, column < columns {
            if left[row] == right[column] {
                pairs.append((row, column))
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }
}
