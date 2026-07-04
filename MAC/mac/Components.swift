import SwiftUI

// A rounded translucent card.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}

struct SectionCap: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textFaint)
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textDim)
    }
}

// Accent (primary) button.
struct AccentButtonStyle: ButtonStyle {
    var big = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 15 : 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.92))
            .padding(.vertical, big ? 12 : 7)
            .padding(.horizontal, big ? 18 : 14)
            .frame(maxWidth: big ? .infinity : nil)
            .background(configuration.isPressed ? Theme.accentHi : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

// Ghost (secondary) button.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(configuration.isPressed ? Theme.fieldHi : Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// Secondary prominent (blue) button — used for "Update core packages".
struct BlueButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 7).padding(.horizontal, 14)
            .background(configuration.isPressed
                        ? Color(nsColor: NSColor(srgbRed: 86/255, green: 130/255, blue: 172/255, alpha: 1))
                        : Color(nsColor: NSColor(srgbRed: 70/255, green: 110/255, blue: 150/255, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
    }
}

extension View {
    func accentButton(big: Bool = false) -> some View { buttonStyle(AccentButtonStyle(big: big)) }
    func ghostButton() -> some View { buttonStyle(GhostButtonStyle()) }
    func blueButton() -> some View { buttonStyle(BlueButtonStyle()) }
}

// Dark styled text field.
struct DarkField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

// Dark multiline editor.
struct DarkEditor: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

// A read-only monospace log pane.
struct LogPane: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("logbottom")
            }
            .background(Color(nsColor: NSColor(srgbRed: 18/255, green: 18/255, blue: 20/255, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: text) { withAnimation { proxy.scrollTo("logbottom", anchor: .bottom) } }
        }
    }
}

// A styled Picker (menu) with dark chrome.
struct DarkPicker: View {
    let options: [String]
    @Binding var selection: String
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(opt) { selection = opt }
            }
        } label: {
            HStack {
                Text(selection).foregroundStyle(.white).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// A toggle row with a title, status text, and a switch.
struct ToggleRow: View {
    let title: String
    let status: String
    let statusColor: Color
    @Binding var isOn: Bool
    var onChange: (Bool) -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(status).font(.system(size: 11)).foregroundStyle(statusColor)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .onChange(of: isOn) { onChange(isOn) }
        }
    }
}
