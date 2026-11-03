import SwiftUI

/// 黒板の部品をサンプルで並べる確認画面（開発用）。
struct BoardGallery: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(Self.entries, id: \.name) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.headline).foregroundStyle(.secondary)
                        BoardView(content: entry.content)
                            .frame(height: 620)
                    }
                }
            }
            .padding()
        }
        .environment(\.boardImageProvider, BoardImageProvider { BoardSamples.image(for: $0) })
        .navigationTitle("黒板の部品")
    }

    struct Entry {
        let name: String
        let content: BoardContent
    }

    static var entries: [Entry] {
        BoardComponent.Kind.allCases.map { Entry(name: $0.rawValue, content: BoardSamples.content($0)) }
            + [Entry(name: "fallback（読めない入力）",
                     content: BoardTools.content(toolName: BoardTools.showBoardName, input: Data(BoardSamples.brokenJSON.utf8)))]
    }
}

#Preview {
    NavigationStack { BoardGallery() }
}
