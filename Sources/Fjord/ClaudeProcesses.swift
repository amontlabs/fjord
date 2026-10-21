import Darwin
import Foundation

extension Claude {
    /// A process as far as the permission check needs it.
    struct ProcessInfo: Equatable, Sendable {
        /// When the process started (ms since 1970).
        var startedMs: Int64
        var arguments: [String]
    }

    /// The system's process table, as a pair of lookups (tests give a fake one).
    struct ProcessLister: Sendable {
        var children: @Sendable (Int32) -> [Int32]
        var info: @Sendable (Int32) -> ProcessInfo?

        /// libproc for the children of a process and its start time, and `KERN_PROCARGS2` for its arguments.
        static let system = ProcessLister(children: { pid in
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
            guard bytes > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
            let used = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard used > 0 else { return [] }
            return pids.prefix(Int(used) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
        }, info: { pid in
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size,
                  let arguments = arguments(of: pid) else { return nil }
            return ProcessInfo(startedMs: Int64(bsd.pbi_start_tvsec) * 1000 + Int64(bsd.pbi_start_tvusec) / 1000, arguments: arguments)
        })

        /// argv of a process: `KERN_PROCARGS2` holds argc, the executable path, padding NULs, then argc strings.
        static func arguments(of pid: Int32) -> [String]? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var length = 0
            guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
            let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
            var i = MemoryLayout<Int32>.size
            while i < length, buffer[i] != 0 { i += 1 }  // the executable path
            while i < length, buffer[i] == 0 { i += 1 }  // its padding
            var arguments: [String] = []
            while arguments.count < argc, i < length {
                var end = i
                while end < length, buffer[end] != 0 { end += 1 }
                arguments.append(String(decoding: buffer[i..<end], as: UTF8.self))
                i = end + 1
            }
            return arguments
        }
    }

    /// Whether `command`, approved at a permission prompt, is running under `root` (the session's Claude Code process):
    /// a descendant that started at or after the prompt and has the command in its arguments. Claude Code runs a Bash
    /// call as `zsh -c '… && eval '<command, single quotes escaped as '"'"'>' …'`, so the command is looked for as it is
    /// and as that shell quoting of it.
    static func commandStarted(_ command: String, after startedMs: Int64, under root: Int32, processes: ProcessLister) -> Bool {
        guard !command.isEmpty else { return false }
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        var seen: Set<Int32> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in processes.children(parent) where seen.insert(child).inserted {
                queue.append(child)
                guard let info = processes.info(child), info.startedMs >= startedMs else { continue }
                if info.arguments.contains(where: { $0.contains(command) || $0.contains(quoted) }) { return true }
            }
        }
        return false
    }

    /// Takes away the notes of Bash prompts whose command has started: the user said yes, and Claude Code writes nothing
    /// to the transcript until the command ends, so the process starting is the only sign the prompt is over. Other tools
    /// (MCP, WebFetch, Edit…) run no process of their own, so they still end with their result in the transcript.
    /// Returns the notes still pending.
    static func clearingStartedCommands(_ notes: [PermissionNote], pid: Int32?, processes: ProcessLister) -> [PermissionNote] {
        guard let pid else { return notes }
        return notes.filter { note in
            guard note.tool == "Bash", let command = note.input["command"] as? String,
                  commandStarted(command, after: note.createdMs, under: pid, processes: processes) else { return true }
            try? FileManager.default.removeItem(at: note.file)
            return false
        }
    }
}
