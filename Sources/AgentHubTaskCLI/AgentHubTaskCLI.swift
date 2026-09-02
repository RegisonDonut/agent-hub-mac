import Foundation

@main
struct AgentHubTaskCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, let taskID = args.dropFirst().first else {
            usage(); exit(2)
        }
        let taskName = command == "register" ? (args.count > 2 ? args[2] : taskID) : nil
        var sessionID: String?
        var quota = 0.0
        var work = 0.0
        if command == "session-start" || command == "heartbeat" || command == "session-end" {
            sessionID = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : UUID().uuidString
            var index = args.count > 2 && !args[2].hasPrefix("--") ? 3 : 2
            while index < args.count {
                switch args[index] {
                case "--quota-percent":
                    if index + 1 < args.count { quota = Double(args[index + 1]) ?? 0; index += 2 } else { index += 1 }
                case "--work-seconds":
                    if index + 1 < args.count { work = Double(args[index + 1]) ?? 0; index += 2 } else { index += 1 }
                default: index += 1
                }
            }
        }
        let types = ["register": "register", "session-start": "session_start", "heartbeat": "heartbeat", "session-end": "session_end"]
        guard let type = types[command] else { usage(); exit(2) }
        var event: [String: Any] = [
            "type": type,
            "task_id": taskID,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let taskName { event["task_name"] = taskName }
        if let sessionID { event["session_id"] = sessionID }
        if quota != 0 { event["quota_percent"] = quota }
        if work != 0 { event["work_seconds"] = work }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Application Support/AgentHub/task-observations", isDirectory: true)
        let file = directory.appendingPathComponent("tasks.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let line = try JSONSerialization.data(withJSONObject: event) + Data([0x0a])
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
            } else { try line.write(to: file, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            print(sessionID ?? taskID)
        } catch { fputs("agenthub-task: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func usage() {
        print("用法：agenthub-task register <任务ID> <任务名称> | session-start <任务ID> [SessionID] | heartbeat <任务ID> [SessionID] [--quota-percent N] [--work-seconds N] | session-end <任务ID> [SessionID] [--work-seconds N]")
    }
}
