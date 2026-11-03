import Testing

/// mutating なメソッドの戻り値を確かめる（#expect の中では mutating を呼べないため、外で評価して渡す）。
func expectStep(_ actual: Bool, _ expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
