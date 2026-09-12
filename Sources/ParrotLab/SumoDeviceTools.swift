import Foundation

enum SumoDeviceTools {
    static func rfCommand(md5: String, token: String, enable: Bool) -> String? {
        guard launchCommand(md5: md5, token: token) != nil else { return nil }
        let prefix = "__PARROTLAB_SUMO_\(token)__="
        return "cd /data/ftp/internal_000 || { echo \(prefix)ERROR_DIRECTORY; exit; }; " +
            "D=$(md5sum parrot_sumo_rf_lab.sh); D=${D%% *}; " +
            "[ \"$D\" = \(md5) ] || { echo \(prefix)ERROR_DIGEST; exit; }; " +
            "if sh ./parrot_sumo_rf_lab.sh apply-profile \(enable ? "epa2_pd14" : "stock"); then " +
            "trap '' HUP; (sleep 3; reboot) </dev/null >/tmp/parrotlab-sumo-rf-reboot.log 2>&1 & " +
            "echo \(prefix)RF_QUEUED; else echo \(prefix)ERROR_PROFILE; fi; exit"
    }

    /// Fixed paths: never execute a user-supplied path or overwrite a running B29.
    /// The ignored SIGHUP disposition and redirected descriptors survive Telnet loss.
    static func launchCommand(md5: String, token: String) -> String? {
        guard md5.count == 32, md5.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              UUID(uuidString: token) != nil else { return nil }
        let prefix = "__PARROTLAB_SUMO_\(token)__="
        return "cd /data/ftp/internal_000 || { echo \(prefix)ERROR_DIRECTORY; exit; }; " +
            "[ -f B29 ] || { echo \(prefix)ERROR_B29_MISSING; exit; }; " +
            "[ -x /bin/DragonStarter.sh ] || { echo \(prefix)ERROR_STARTER_MISSING; exit; }; " +
            "D=$(md5sum start_sumo_b29.sh); D=${D%% *}; " +
            "[ \"$D\" = \(md5) ] || { echo \(prefix)ERROR_DIGEST; exit; }; " +
            "chmod +x start_sumo_b29.sh B29 || { echo \(prefix)ERROR_CHMOD; exit; }; " +
            "trap '' HUP; (sleep 2; exec ./start_sumo_b29.sh) " +
            "</dev/null >/tmp/parrotlab-b29-launch.log 2>&1 & " +
            "echo \(prefix)QUEUED; exit"
    }

    static func selfTest() -> Bool {
        let token = UUID().uuidString
        guard let command = launchCommand(md5: String(repeating: "a", count: 32), token: token),
              command.contains("trap '' HUP"), command.contains("</dev/null"),
              command.contains("exec ./start_sumo_b29.sh"),
              command.contains("[ -f B29 ]"),
              command.contains("[ -x /bin/DragonStarter.sh ]"),
              !command.contains("/usr/bin/DragonStarter.sh"),
              !command.contains("kill ") else { return false }
        guard let rf = rfCommand(md5: String(repeating: "a", count: 32), token: token, enable: true),
              rf.contains("apply-profile epa2_pd14; then"),
              !rf.contains("pd16"), !rf.contains("maxp"),
              rfCommand(md5: String(repeating: "a", count: 32), token: token, enable: false)?.contains("apply-profile stock; then") == true else { return false }
        return launchCommand(md5: "bad; reboot", token: token) == nil &&
            launchCommand(md5: String(repeating: "a", count: 32), token: "bad; reboot") == nil
    }
}
