import Foundation

/// Opt-in, per-user permission for exactly two commands; never grant a root shell.
enum LidSleepPasswordlessAccess {
  /// Inspect explicit NOPASSWD entries, not sudo's credential cache. Listing a
  /// permitted command alone does not prove that executing it is passwordless.
  static func hasExistingPermission(in listing: String) -> Bool {
    let required: Set<String> = [
      "/usr/bin/pmset -a disablesleep 0", "/usr/bin/pmset -a disablesleep 1",
    ]
    var allowed = Set<String>()
    for line in listing.components(separatedBy: .newlines) {
      guard line.contains("(ALL)") || line.contains("(root)"),
        let marker = line.range(of: "NOPASSWD:"),
        line.range(of: "PASSWD:", range: marker.upperBound..<line.endIndex) == nil
      else { continue }
      allowed.formUnion(
        line[marker.upperBound...].split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }
    return required.isSubset(of: allowed)
  }

  static func existingPermissionAvailable() -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", "-l"]
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in
      new
    }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return process.terminationStatus == 0
        && hasExistingPermission(in: String(data: data, encoding: .utf8) ?? "")
    } catch { return false }
  }

  static func rulePath(for username: String) -> String? {
    guard username.range(of: #"\A[A-Za-z_][A-Za-z0-9_-]*\z"#, options: .regularExpression) != nil
    else { return nil }
    return "/private/etc/sudoers.d/pimac-lid-sleep-\(username)"
  }

  static func ruleContent(for username: String) -> String? {
    guard rulePath(for: username) != nil else { return nil }
    return """
      # Pi Mac: allow only system sleep on/off for this user.
      \(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

      """
  }

  static func installationScript(for username: String) -> String? {
    guard let path = rulePath(for: username), let content = ruleContent(for: username) else {
      return nil
    }
    return """
      set -eu
      /usr/sbin/visudo -c >/dev/null
      # Do not edit the main sudoers file or silently install an ignored rule.
      /usr/bin/grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+(/private)?/etc/sudoers[.]d/?([[:space:]]|$)' /private/etc/sudoers || {
        echo 'sudoers does not include /etc/sudoers.d; no changes made.' >&2
        exit 1
      }
      target=\(LidSleepController.shellQuote(path))
      [ ! -e "$target" ] && [ ! -L "$target" ] || {
        echo 'Permission file already exists; refusing to overwrite.' >&2
        exit 1
      }
      /bin/mkdir -p /private/etc/sudoers.d
      tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/.pimac-lid-XXXXXX)
      trap '/bin/rm -f "$tmp"' EXIT
      printf '%s' \(LidSleepController.shellQuote(content)) > "$tmp"
      /usr/sbin/chown root:wheel "$tmp"
      /bin/chmod 440 "$tmp"
      /usr/sbin/visudo -cf "$tmp" >/dev/null
      # Atomic no-overwrite publication in a root-owned directory.
      /bin/ln "$tmp" "$target"
      if ! /usr/sbin/visudo -c >/dev/null; then
        /bin/rm -f "$target"
        exit 1
      fi
      """
  }

  static func removalScript(for username: String, restoreSleep: Bool) -> String? {
    guard let path = rulePath(for: username) else { return nil }
    return """
      set -eu
      \(restoreSleep ? "/usr/bin/pmset -a disablesleep 0" : ":")
      /bin/rm -f \(LidSleepController.shellQuote(path))
      """
  }
}
