/// Press-and-hold repeat for a key: fires on press, then (when `repeats`) after 0.4 s every
/// 0.06 s until released.
struct KeyRepeater {
    private var task: Task<Void, Never>?

    mutating func begin(repeats: Bool, _ action: @escaping () -> Void) {
        guard task == nil else { return }
        action()
        guard repeats else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    mutating func end() {
        task?.cancel()
        task = nil
    }
}
