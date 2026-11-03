import SwiftUI

/// 作文の構成メモ。段落を左から並べ、矢印でつなぐ。
struct EssayOutlineView: View {
    let model: EssayOutline
    @Environment(\.boardAnimated) private var animated
    @State private var revealed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "pencil.line")
                Text("テーマ：\(model.theme)")
            }
            .font(Chalk.font(30, weight: .bold))
            .foregroundStyle(Chalk.blue)

            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(model.sections.enumerated()), id: \.offset) { i, section in
                    if i > 0 {
                        Image(systemName: "arrow.right")
                            .font(Chalk.font(30, weight: .bold))
                            .foregroundStyle(Chalk.faint)
                            .padding(.top, 20)
                    }
                    column(section)
                        .opacity(!animated || i < revealed ? 1 : 0)
                        .offset(y: !animated || i < revealed ? 0 : 20)
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            guard animated else { return }
            for i in model.sections.indices {
                try? await Task.sleep(for: .milliseconds(i == 0 ? 150 : 500))
                withAnimation(.spring(duration: 0.5)) { revealed = i + 1 }
            }
        }
    }

    private func column(_ section: EssayOutline.Section) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.heading)
                .font(Chalk.font(30, weight: .heavy))
                .foregroundStyle(Chalk.yellow)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Chalk.yellow).frame(height: 3) }
            ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                let open = point.hasPrefix("？") || point.hasPrefix("?")
                Text(point)
                    .font(Chalk.font(24, weight: .medium))
                    .foregroundStyle(open ? Chalk.pink : Chalk.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(open ? 0 : 0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(open ? Chalk.pink : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Chalk.faint, lineWidth: 2))
    }
}
