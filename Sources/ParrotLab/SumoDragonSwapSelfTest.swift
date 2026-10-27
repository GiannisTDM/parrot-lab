import CryptoKit
import Foundation

/// Execute the shipping helper against a temporary filesystem and fake mount
/// commands. No network, device, root privilege or real remount is involved.
enum SumoDragonSwapSelfTest {
    static func run() -> Bool {
        do {
            let script = try BebopToolInstaller.sumoScript(.sumoB29Replacement).0
            func check(_ value: Bool, _ name: String) throws {
                if !value { throw NSError(domain: "SumoSwapTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            }
            let fixture = try Fixture(script: script)
            defer { fixture.remove() }
            let originalInode = try fixture.inode("usr/bin/dragon-prog")
            for _ in 0..<3 {
                try check(fixture.run(["install", fixture.b29Digest]).status == 0, "install")
                try check(fixture.contents("usr/bin/dragon-prog") == fixture.b29 &&
                          fixture.contents("usr/bin/dragon-prog.parrotlab-original") == fixture.stock &&
                          fixture.inode("usr/bin/dragon-prog.parrotlab-original") == originalInode &&
                          fixture.mode() == "ro", "backup, active path and mount preservation")
                try check(fixture.run(["install", fixture.b29Digest]).output.contains("ALREADY_INSTALLED"), "repeat install")
                try check(fixture.run(["restore"]).status == 0, "restore")
                try check(fixture.contents("usr/bin/dragon-prog") == fixture.stock &&
                          fixture.contents("usr/bin/B29") == fixture.b29 &&
                          fixture.inode("usr/bin/dragon-prog") == originalInode &&
                          fixture.permissions("usr/bin/dragon-prog") == 0o751 && fixture.mode() == "ro", "restored names, metadata and B29")
                try check(fixture.run(["restore"]).output.contains("ALREADY_ORIGINAL"), "repeat restore")
            }
            try fixture.write("mount-mode", Data("rw".utf8))
            try check(fixture.run(["install", fixture.b29Digest]).status == 0 && fixture.mode() == "rw", "preserve writable mount")
            try fixture.write("usr/bin/dragon-prog.parrotlab-original", Data("changed backup".utf8))
            try check(fixture.run(["restore"]).status != 0 && fixture.contents("usr/bin/dragon-prog") == fixture.b29, "refuse corrupt backup")

            let failure = try Fixture(script: script)
            defer { failure.remove() }
            try check(failure.run(["install", String(repeating: "0", count: 32)]).status != 0 &&
                      failure.contents("usr/bin/dragon-prog") == failure.stock, "reject upload digest")
            try check(failure.run(["install", failure.b29Digest], extra: ["SWAP_FAIL_MOUNT": "1"]).status != 0 &&
                      failure.contents("usr/bin/dragon-prog") == failure.stock && failure.mode() == "ro", "failed remount")
            try check(failure.run(["install", failure.b29Digest], extra: ["SWAP_FAIL_RENAME": "install"]).status != 0 &&
                      failure.contents("usr/bin/dragon-prog") == failure.stock && failure.mode() == "ro", "failed install rename preserves stock")
            try check(failure.run(["install", failure.b29Digest]).status == 0, "recover interrupted install")
            try check(failure.run(["restore"], extra: ["SWAP_FAIL_RENAME": "restore"]).status != 0 &&
                      failure.contents("usr/bin/dragon-prog") == failure.b29 &&
                      failure.contents("usr/bin/dragon-prog.parrotlab-original") == failure.stock && failure.mode() == "ro", "failed restore remains recoverable")
            try check(failure.run(["restore"]).status == 0, "recover interrupted restore")
            try failure.write("usr/bin/dragon-prog", Data("unexpected executable".utf8))
            try check(failure.run(["install", failure.b29Digest]).status != 0, "reject changed active executable")

            let unmanaged = try Fixture(script: script)
            defer { unmanaged.remove() }
            try unmanaged.write("usr/bin/dragon-prog.parrotlab-original", Data("existing backup".utf8))
            try check(unmanaged.run(["install", unmanaged.b29Digest]).status != 0 &&
                      unmanaged.contents("usr/bin/dragon-prog.parrotlab-original") == Data("existing backup".utf8), "never overwrite unmanaged backup")
            try FileManager.default.removeItem(at: unmanaged.path("usr/bin/dragon-prog.parrotlab-original"))
            try FileManager.default.createSymbolicLink(at: unmanaged.path("usr/bin/B29"), withDestinationURL: unmanaged.path("usr/bin/dragon-prog"))
            try check(unmanaged.run(["install", unmanaged.b29Digest]).status != 0, "reject symlink")
            try FileManager.default.removeItem(at: unmanaged.path("usr/bin/B29"))
            try FileManager.default.createDirectory(at: unmanaged.path("tmp/parrotlab-sumo-dragon-swap.lock"), withIntermediateDirectories: false)
            try check(unmanaged.run(["install", unmanaged.b29Digest]).status != 0, "serialize concurrent replacements")

            // Run the actual multi-file bridge commands, including every byte
            // value, and verify marker numbering carries across file boundaries.
            let bytes = Data((0..<512).map { UInt8(truncatingIfNeeded: $0) })
            let asset = BebopInstalledAsset(assetName: "fixture", remoteName: "fixture.bin", byteCount: bytes.count,
                                           sha256: "", md5: md5(bytes))
            let token = UUID()
            let first = SumoBridgeUploader.uploadCommands(data: bytes, asset: asset, token: token)
            let second = SumoBridgeUploader.uploadCommands(data: bytes, asset: asset, token: token, firstIndex: first.count)
            let commands = (first + second).joined(separator: "\n")
                .replacingOccurrences(of: "/data/ftp/internal_000", with: failure.path("data/ftp/internal_000").path)
                .replacingOccurrences(of: "/bin/DragonStarter.sh", with: failure.path("bin/DragonStarter.sh").path)
            let transfer = failure.runShell(commands)
            try check(transfer.status == 0 && failure.contents("data/ftp/internal_000/fixture.bin") == bytes &&
                      transfer.output.contains("=\(first.count + second.count - 1)\n"), "binary bridge transfer and final ACK")
            print("Sumo Dragon replacement, restore and interruption self-tests passed")
            return true
        } catch {
            fputs("Sumo Dragon swap self-test failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/parrotlab-sumo-swap-test.\(UUID().uuidString)")
        let stock = Data("original Sumo fixture".utf8)
        let b29 = Data([0x7f, 0x45, 0x4c, 0x46, 0, 255, 10, 13, 36, 39])
        var b29Digest: String { md5(b29) }
        init(script: Data) throws {
            for folder in ["usr/bin", "bin", "tmp", "data/ftp/internal_000", "test-bin"] {
                try FileManager.default.createDirectory(at: path(folder), withIntermediateDirectories: true)
            }
            try write(".parrotlab-test-root", Data())
            try write("helper.sh", script)
            try write("mount-mode", Data("ro".utf8))
            try write("usr/bin/dragon-prog", stock, mode: 0o751)
            try write("data/ftp/internal_000/parrotlab-sumo-B29.upload", b29)
            try write("bin/DragonStarter.sh", Data("#!/bin/sh\nexit 0\n".utf8), mode: 0o755)
            let mocks = [
                "id": "#!/bin/sh\necho 0\n",
                "sync": "#!/bin/sh\nexit 0\n",
                "md5sum": "#!/bin/sh\nD=$(/sbin/md5 -q \"$1\") || exit 1\nprintf '%s  %s\\n' \"$D\" \"$1\"\n",
                "mount": """
                #!/bin/sh
                if [ "$#" = 0 ]; then
                    MODE=$(cat "$PARROTLAB_SUMO_SWAP_TEST_ROOT/mount-mode")
                    echo "/dev/test on / type ext4 ($MODE,relatime)"
                elif [ "$2" = remount,rw ]; then
                    [ "${SWAP_FAIL_MOUNT:-}" != 1 ] || exit 1
                    echo rw > "$PARROTLAB_SUMO_SWAP_TEST_ROOT/mount-mode"
                elif [ "$2" = remount,ro ]; then
                    echo ro > "$PARROTLAB_SUMO_SWAP_TEST_ROOT/mount-mode"
                else exit 1; fi
                """,
                "mv": """
                #!/bin/sh
                if [ "$1" = -f ]; then
                    [ -x "$PARROTLAB_SUMO_SWAP_TEST_ROOT/usr/bin/dragon-prog" ] || exit 77
                    case "${SWAP_FAIL_RENAME:-}:$2" in
                        install:*/usr/bin/B29|restore:*/usr/bin/dragon-prog.parrotlab-original) exit 1 ;;
                    esac
                fi
                exec /bin/mv "$@"
                """
            ]
            for (name, text) in mocks { try write("test-bin/\(name)", Data((text + "\n").utf8), mode: 0o755) }
        }
        func path(_ name: String) -> URL { root.appendingPathComponent(name) }
        func write(_ name: String, _ data: Data, mode: Int = 0o644) throws {
            try data.write(to: path(name))
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path(name).path)
        }
        func contents(_ name: String) -> Data? { try? Data(contentsOf: path(name)) }
        func inode(_ name: String) throws -> UInt64 { (try FileManager.default.attributesOfItem(atPath: path(name).path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0 }
        func permissions(_ name: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: path(name).path)[.posixPermissions] as? NSNumber)?.intValue ?? 0 }
        func mode() -> String { String(data: contents("mount-mode") ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String], extra: [String: String] = [:]) -> (status: Int32, output: String) {
            execute([path("helper.sh").path] + arguments, extra: extra)
        }
        func runShell(_ commands: String) -> (status: Int32, output: String) { execute(["-c", commands], extra: [:]) }
        private func execute(_ arguments: [String], extra: [String: String]) -> (status: Int32, output: String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = arguments
            process.environment = ["PARROTLAB_SUMO_SWAP_TEST_ROOT": root.path,
                                   "PATH": path("test-bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"].merging(extra) { _, value in value }
            process.standardOutput = output; process.standardError = output
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
