import SwiftUI

/// キャラに会って選ぶ画面（#123）。触ったキャラが席から舞台へ出てきて、その声で短く自己紹介する。
/// 替えても記憶と学習記録は共通で、次の勉強からそのキャラになる。
struct CharacterPickerView: View {
    let model: SessionAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picker: CharacterPickerModel?

    /// 起動引数 `-showAllCharacters`：まだ選べないキャラも出す（確認用）
    private static var showsAll: Bool { ProcessInfo.processInfo.arguments.contains("-showAllCharacters") }

    private var characters: [TeacherCharacter] {
        let catalog = model.preferences.catalog
        return Self.showsAll ? catalog.characters : catalog.selectableCharacters
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.96, blue: 0.90)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            if let picker {
                CharacterPickerContent(picker: picker, lipSync: model.lipSync, onClose: close)
            }
        }
        .task {
            guard picker == nil else { return }
            let voice = model.introVoice()
            let preferences = model.preferences
            let model = model
            picker = CharacterPickerModel(
                characters: characters, selected: preferences.selectedCharacter, voice: voice,
                useVoice: { model.useVoice(of: $0, on: voice) },
                save: { preferences.characterID = $0 }
            )
        }
    }

    private func close() {
        picker?.close()
        // まだ選んでいなければ、今の先生を選んだことにする（毎回開かない）
        if model.preferences.characterID == nil { model.preferences.characterID = model.preferences.selectedCharacter.id }
        dismiss()
    }
}

/// 画面の文字。丸ゴシックで、先生に会う場面のやわらかさを出す
private enum PickerFont {
    static func maru(_ size: CGFloat) -> Font { .custom("HiraMaruGothicProN-W4", size: size) }
}

private extension TeacherCharacter {
    /// そのキャラの色
    var tint: Color { Color(uiColor: baseColor) }

    /// ボタンや名札の、白い文字が読めるように濃くした色
    var deepTint: Color {
        var (hue, saturation, brightness, alpha) = (CGFloat.zero, CGFloat.zero, CGFloat.zero, CGFloat.zero)
        baseColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(uiColor: UIColor(hue: hue, saturation: max(saturation, 0.55), brightness: 0.56, alpha: 1))
    }

    private var baseColor: UIColor {
        let hex = UInt32(color.dropFirst(), radix: 16) ?? 0x9CCFA8
        return UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }

    /// いま選んでいることの言い方
    var currentLabel: String { relation == .teacher ? "いまの先生" : "いまの仲間" }
}

private struct CharacterPickerContent: View {
    let picker: CharacterPickerModel
    let lipSync: LipSyncPlayer
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// あいさつが終わって閉じるまでの間（もう 1 度押せないように）
    @State private var isLeaving = false
    @State private var bubbleScale = 1.0

    /// 席と舞台を行き来する動き
    private var hop: Animation? { reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.28) }

    var body: some View {
        GeometryReader { geometry in
            let layout = CharacterPickerLayout(size: geometry.size, count: picker.characters.count)
            ZStack(alignment: .topLeading) {
                header.placed(layout.header)
                backdrop.placed(layout.hero)
                hint.placed(layout.hint)
                ForEach(Array(picker.characters.enumerated()), id: \.element.id) { index, character in
                    seat(character, tag: layout.tag(index), figure: layout.figure(index))
                }
                // キャラは 1 人につき 1 つの表示を動かす。作り直すと読み込みで消えるので、席と舞台で分けない
                ForEach(Array(picker.characters.enumerated()), id: \.element.id) { index, character in
                    let isOnStage = picker.focused == character
                    avatar(character)
                        .placed(CharacterPickerLayout.figureFrame(isOnStage ? layout.hero : layout.figure(index), kind: character.look.kind))
                        .zIndex(isOnStage ? 2 : 1)
                }
                .zIndex(1)
                stageTapArea.placed(layout.hero).zIndex(3)
                bubble.placed(layout.bubble).zIndex(4)
                plate.placed(layout.plate).zIndex(4)
                chooseButton.placed(layout.button).zIndex(4)
            }
            .animation(hop, value: picker.focused)
        }
    }

    private var header: some View {
        HStack {
            Text("だれといっしょに勉強する？")
                .font(PickerFont.maru(32))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Button("とじる", action: onClose)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .buttonStyle(.bordered)
                .accessibilityIdentifier("picker_close")
        }
    }

    /// 舞台に出ているキャラの色の、大きな丸
    private var backdrop: some View {
        Circle()
            .fill(picker.focused.tint.opacity(0.55))
            .scaleEffect(0.96)
            .accessibilityHidden(true)
    }

    private var hint: some View {
        Text("さわると、お話しするよ")
            .font(PickerFont.maru(17))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func avatar(_ character: TeacherCharacter) -> some View {
        let isSpeaking = picker.speakingID == character.id
        return AvatarView(
            state: isSpeaking ? (picker.isGreeting ? .praise : .talking) : .idle,
            lipSync: isSpeaking ? lipSync : nil,
            look: character.look,
            mannerisms: character.mannerisms,
            studioLight: true
        )
        .accessibilityHidden(true)
    }

    /// 席：色の丸と名札。舞台に出ている間は「前にいるよ」
    private func seat(_ character: TeacherCharacter, tag: CGRect, figure: CGRect) -> some View {
        let isFocused = picker.focused == character
        let isCurrent = picker.currentID == character.id
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(character.tint.opacity(isFocused ? 0 : 0.5))
                .overlay {
                    if isFocused {
                        Circle().strokeBorder(character.deepTint.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, dash: [7, 7]))
                        Text("前にいるよ")
                            .font(PickerFont.maru(15))
                            .foregroundStyle(character.deepTint)
                    }
                }
                .padding(figure.width * 0.06)
                .placed(figure, in: tag.union(figure))
            VStack(spacing: 2) {
                Text(character.callName)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isFocused ? character.deepTint : .white.opacity(0.85)))
                if isCurrent {
                    Text(character.currentLabel)
                        .font(PickerFont.maru(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .placed(tag, in: tag.union(figure))
        }
        .opacity(picker.isGreeting && !isFocused ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { Task { await picker.meet(character) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("character_\(character.id)")
        .accessibilityLabel(character.callName)
        .accessibilityValue(picker.speakingID == character.id ? "話している" : (isCurrent ? character.currentLabel : ""))
        .placed(tag.union(figure))
    }

    /// 舞台のキャラに触ると、もう 1 度話す
    private var stageTapArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { Task { await picker.meet(picker.focused) } }
            .accessibilityHidden(true)
    }

    private var bubble: some View {
        // 文の切れ目で改行して、言葉の途中で折り返しにくくする
        Text(picker.line.replacingOccurrences(of: "。", with: "。\n").trimmingCharacters(in: .newlines))
            .font(PickerFont.maru(21))
            .lineSpacing(5)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .background(SpeechBubble(tail: 14).fill(.white).shadow(color: picker.focused.deepTint.opacity(0.25), radius: 0, y: 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(bubbleScale, anchor: .bottom)
            .onChange(of: picker.line) {
                guard !reduceMotion else { return }
                bubbleScale = 0.9
                withAnimation(.spring(duration: 0.35, bounce: 0.45)) { bubbleScale = 1 }
            }
            .accessibilityIdentifier("picker_intro")
            .accessibilityElement(children: .combine)
    }

    private var plate: some View {
        VStack(spacing: 0) {
            Text(picker.focused.callName)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(picker.focused.tagline)
                .font(PickerFont.maru(15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var chooseButton: some View {
        Button {
            isLeaving = true
            Task {
                await picker.choose(picker.focused)
                // 声が出なかったときも、喜ぶところを少し見せてから閉じる
                try? await Task.sleep(for: .milliseconds(600))
                onClose()
            }
        } label: {
            Text("\(picker.focused.callName)にする")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white)
                .background(Capsule().fill(picker.focused.deepTint))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(picker.isGreeting || isLeaving)
        .accessibilityIdentifier("picker_choose")
    }
}

/// 下にしっぽのある吹き出し
private struct SpeechBubble: Shape {
    let tail: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
        var path = Path(roundedRect: body, cornerRadius: 24, style: .continuous)
        path.move(to: CGPoint(x: rect.midX - tail, y: body.maxY - 1))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + tail, y: body.maxY - 1))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// 画面の座標のとおりに置く
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }

    /// `parent` の中の座標に置く
    func placed(_ rect: CGRect, in parent: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX - parent.minX, y: rect.midY - parent.minY)
    }
}
