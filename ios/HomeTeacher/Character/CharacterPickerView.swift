import SwiftUI

/// キャラに会って選ぶ画面（#123）。動いているキャラに触ると、その声で短く自己紹介する。
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

private struct CharacterPickerContent: View {
    let picker: CharacterPickerModel
    let lipSync: LipSyncPlayer
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height
            let count = picker.characters.count
            let columns = isWide ? min(max(count, 1), 4) : min(max(count, 1), 4)
            VStack(spacing: isWide ? 14 : 22) {
                HStack {
                    Text("だれといっしょに勉強する？")
                        .font(.system(size: isWide ? 30 : 36, weight: .bold, design: .rounded))
                    Spacer()
                    Button("とじる", action: onClose)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("picker_close")
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                        ForEach(picker.characters) { character in
                            card(character, height: cardHeight(geometry.size, count: count, columns: columns, isWide: isWide))
                        }
                    }
                    .padding(4)
                }
                detail
            }
            .padding(isWide ? 20 : 28)
        }
    }

    private func cardHeight(_ size: CGSize, count: Int, columns: Int, isWide: Bool) -> CGFloat {
        let rows = max(1, (count + columns - 1) / columns)
        let available = size.height - (isWide ? 240 : 320)
        let byHeight = available / CGFloat(rows) - 14
        return max(180, min(byHeight, isWide ? 420 : 480))
    }

    private func card(_ character: TeacherCharacter, height: CGFloat) -> some View {
        let isFocused = picker.focused == character
        let isSpeaking = picker.speakingID == character.id
        return VStack(spacing: 4) {
            AvatarView(
                state: isSpeaking ? .talking : .idle,
                lipSync: isSpeaking ? lipSync : nil,
                look: character.look,
                mannerisms: character.mannerisms
            )
            .frame(maxWidth: .infinity)
            .frame(height: height - 58)
            Text(character.callName)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(character.tagline)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.white.opacity(isFocused ? 0.95 : 0.55))
                .stroke(isFocused ? Color.orange : .clear, lineWidth: 4)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { Task { await picker.meet(character) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("character_\(character.id)")
        .accessibilityLabel(character.callName)
        .accessibilityValue(isSpeaking ? "話している" : "")
    }

    private var detail: some View {
        VStack(spacing: 12) {
            Text(picker.focused.intro)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 56)
                .accessibilityIdentifier("picker_intro")
            Button {
                Task {
                    await picker.choose(picker.focused)
                    onClose()
                }
            } label: {
                Text("\(picker.focused.callName)にする")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .frame(maxWidth: 480)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(picker.isGreeting)
            .accessibilityIdentifier("picker_choose")
        }
    }
}
