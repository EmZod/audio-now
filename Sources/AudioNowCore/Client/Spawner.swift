import Foundation

/// Detached daemon spawn: posix_spawn of our own binary with SETSID —
/// no double-fork needed on macOS, no launchd. The CLI never waits;
/// when it exits, the daemon reparents to launchd, which reaps it.
public enum Spawner {
    public static func spawnDetachedDaemon() throws {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        var size = UInt32(pathBuf.count)
        guard _NSGetExecutablePath(&pathBuf, &size) == 0 else {
            throw AudioNowError.spawnFailed("_NSGetExecutablePath failed")
        }
        let exePath = String(cString: pathBuf)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &fileActions, 1, Paths.logFile, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let args = [exePath, "daemon", "run"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exePath, &fileActions, &attr, &argv, environ)
        guard rc == 0 else {
            throw AudioNowError.spawnFailed(
                "posix_spawn: \(String(cString: strerror(rc)))")
        }
        // No waitpid — CLI exits soon; launchd reaps the daemon.
    }
}
