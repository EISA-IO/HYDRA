import Foundation

struct CLIVersion: Comparable, Equatable {
    let parts: [Int]

    init(_ parts: Int...) { self.parts = parts }
    private init(parts: [Int]) { self.parts = parts }

    static func parse(_ text: String) -> CLIVersion? {
        guard let match = text.range(of: #"\d+(?:\.\d+){1,3}"#, options: .regularExpression) else { return nil }
        let values = text[match].split(separator: ".").compactMap { Int($0) }
        return values.count >= 2 ? CLIVersion(parts: values) : nil
    }

    static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func updateAvailable(installed: String, latest: String) -> Bool {
        guard let current = parse(installed), let available = parse(latest) else { return false }
        return current < available
    }
}

extension AppState {
    func checkCLIUpdates() {
        if setupBusy { log("(busy — wait for the current step to finish)"); return }
        setupBusy = true
        cliUpdateStatus = "Checking Claude and ChatGPT/Codex…"
        log("")
        log("===== Checking CLI updates =====")
        DispatchQueue.global(qos: .userInitiated).async {
            let shell = Shell.shared
            let checks = [("Claude", "claude", "@anthropic-ai/claude-code"),
                          ("ChatGPT/Codex", "codex", "@openai/codex")]
            var summaries: [String] = []
            for (name, executable, package) in checks {
                guard shell.onPath(executable) else { summaries.append("\(name): not installed"); continue }
                guard shell.onPath("npm") else { summaries.append("\(name): npm unavailable"); continue }
                let installedResult = shell.run(executable, ["--version"], timeout: 15)
                let latestResult = shell.run("npm", ["view", package, "version", "--silent"], timeout: 30)
                let installed = installedResult.out.trimmingCharacters(in: .whitespacesAndNewlines)
                let latest = latestResult.out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard installedResult.code == 0, latestResult.code == 0,
                      CLIVersion.parse(installed) != nil, CLIVersion.parse(latest) != nil else {
                    summaries.append("\(name): check failed"); continue
                }
                let update = CLIVersion.updateAvailable(installed: installed, latest: latest)
                summaries.append("\(name): \(installed) → \(latest) \(update ? "UPDATE AVAILABLE" : "up to date")")
            }
            DispatchQueue.main.async {
                self.cliUpdateStatus = summaries.joined(separator: "   ")
                summaries.forEach { self.log($0) }
                self.setupBusy = false
            }
        }
    }
}
