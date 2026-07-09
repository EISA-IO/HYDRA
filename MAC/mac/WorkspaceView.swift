import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var terminals: TerminalManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ---- toolbar ----
            HStack(spacing: 10) {
                Picker("", selection: $app.agent) {
                    ForEach(app.agentOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: app.agent) { app.saveSettings() }
                .help("Choose which CLI the next terminal launches")

                Button {
                    app.launch()
                } label: {
                    HStack(spacing: 6) { Image(systemName: "plus"); Text("New" + compSuffix()) }
                }
                .accentButton()
                .keyboardShortcut("t", modifiers: .command)
                .help("Open a new \(app.agent) terminal in the folder at right")

                DarkField(placeholder: "~/path/to/project", text: $app.folder)

                if !app.recents.isEmpty {
                    Menu {
                        ForEach(app.recents, id: \.self) { r in
                            Button(FS.base(r) + "  —  " + r) { app.folder = r }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                    .menuStyle(.borderlessButton).frame(width: 30).help("Recent folders")
                }
                Button("Browse…") {
                    if let f = chooseFolder(prompt: "Folder for the next \(app.agent) session", start: app.folder) { app.folder = f }
                }.ghostButton()
            }

            // ---- tab strip ----
            if !terminals.tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(terminals.tabs) { t in TermTabChip(tab: t) }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 34)
            }

            // ---- terminal host ----
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1)))
                if terminals.tabs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "terminal").font(.system(size: 30)).foregroundStyle(Theme.textFaint)
                        Text("No terminals yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textDim)
                        Text("Click “New” to start a Claude or Codex session. It runs right here as a tab —\nopen as many as you like and switch between them.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                        Text("H Headroom · R RTK · C Caveman   ·   ⌘T new terminal")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint).padding(.top, 4)
                    }
                } else {
                    TerminalContainer(manager: terminals)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func badges() -> [String] {
        var b: [String] = []
        if app.headroom { b.append("H") }
        if app.rtkInstalled { b.append("R") }
        if app.cavemanInstalled { b.append("C") }
        return b
    }
    func compSuffix() -> String {
        let b = badges()
        return b.isEmpty ? "" : "  (\(b.joined(separator: "·")))"
    }
}

struct TermTabChip: View {
    @EnvironmentObject var terminals: TerminalManager
    @ObservedObject var tab: TermTab

    var body: some View {
        let selected = terminals.selectedId == tab.id
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Theme.textDim)
                .lineLimit(1)
            Button {
                terminals.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
            .help("Close this terminal")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.20) : Theme.field)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(selected ? Theme.accent.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { terminals.select(tab.id) }
    }

    var statusColor: Color {
        switch tab.status {
        case "working": return Theme.accent
        case "waiting": return Theme.yellow
        case "idle": return Theme.green
        case "exited": return Theme.textFaint
        default: return Theme.green
        }
    }
}
