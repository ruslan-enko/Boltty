import CryptoKit
import AppKit
import Security

/// Puts a release's `Boltty.dmg` in place of the running copy. Nothing is
/// trusted for being on GitHub: the new copy must carry the same designated
/// requirement as the one running — the same signing identity — so a grant
/// for the microphone or Input Monitoring carries over, and a copy nobody
/// here signed is refused.
enum UpdateInstaller {
  enum Failure: Error, LocalizedError, Equatable {
    case download(String)
    case checksum
    case mount(String)
    case noApp
    case wrongVersion(String)
    case signature(String)
    case notWritable(String)
    case replace(String)

    var errorDescription: String? {
      switch self {
      case let .download(reason): "The download failed: \(reason)"
      case .checksum: "The download does not match its checksum."
      case let .mount(reason): "The disk image would not open: \(reason)"
      case .noApp: "The disk image holds no Boltty."
      case let .wrongVersion(found): "The disk image holds Boltty \(found), not the release."
      case let .signature(reason): "The new Boltty is not signed the way this one is (\(reason))."
      case let .notWritable(folder): "Boltty can't write to \(folder)."
      case let .replace(reason): "Boltty could not be replaced: \(reason)"
      }
    }
  }

  static let mountDeadline: TimeInterval = 60
  static let copyDeadline: TimeInterval = 120
  /// How long a relaunched Boltty waits for the one it replaces to quit.
  static let handOverDeadline: TimeInterval = 20
  static let waitArgument = "-boltty.updatedFrom"

  /// Downloads, checks and swaps in the release. The running copy keeps
  /// running; `relaunch` starts the new one.
  static func install(
    dmg: URL, checksum: URL, version: String, over bundle: URL
  ) async throws {
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("boltty-update-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let folder = bundle.deletingLastPathComponent()
    guard FileManager.default.isWritableFile(atPath: folder.path) else {
      throw Failure.notWritable(folder.path)
    }

    let image = work.appendingPathComponent("Boltty.dmg")
    try await download(dmg, to: image)
    let expected = try await expectedDigest(from: checksum)
    guard try digest(of: image) == expected else { throw Failure.checksum }

    let mount = work.appendingPathComponent("mount")
    let attach = await OneShotCommand.run(
      "/usr/bin/hdiutil",
      ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path],
      deadline: mountDeadline, includeStandardError: true, searchPath: false)
    guard let attach, attach.exitCode == 0 else {
      throw Failure.mount(attach?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "timed out")
    }
    defer {
      _ = OneShotCommand.runBlocking(
        "/usr/bin/hdiutil", ["detach", mount.path, "-force"],
        deadline: mountDeadline, searchPath: false)
    }

    guard let found = try? FileManager.default.contentsOfDirectory(
      at: mount, includingPropertiesForKeys: nil
    ).first(where: { $0.pathExtension == "app" }) else { throw Failure.noApp }
    let foundVersion = Bundle(url: found)?.infoDictionary?["CFBundleShortVersionString"] as? String
    guard foundVersion == version else { throw Failure.wrongVersion(foundVersion ?? "?") }

    // Staged beside the old copy, so the swap is a rename on one volume.
    let staged = folder.appendingPathComponent(".Boltty-\(version)-\(UUID().uuidString.prefix(8)).app")
    let copy = await OneShotCommand.run(
      "/usr/bin/ditto", [found.path, staged.path],
      deadline: copyDeadline, includeStandardError: true, searchPath: false)
    guard let copy, copy.exitCode == 0 else {
      try? FileManager.default.removeItem(at: staged)
      throw Failure.replace(copy?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "the copy timed out")
    }
    do {
      // Checked after the copy: what is verified is what will run.
      try verifySignature(of: staged)
      _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)
    } catch {
      try? FileManager.default.removeItem(at: staged)
      throw error
    }
  }

  /// Starts the new copy, which waits for this process to be gone before it
  /// does anything — two Boltty at once would leave the second read-only.
  static func relaunch(_ bundle: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = false
    configuration.arguments = [waitArgument, String(ProcessInfo.processInfo.processIdentifier)]
    _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
  }

  /// Called first thing at launch: a copy started by `relaunch` waits here
  /// for the one it replaced to quit.
  static func waitForReplacedCopy(arguments: [String] = CommandLine.arguments) {
    guard let index = arguments.firstIndex(of: waitArgument), index + 1 < arguments.count,
          let pid = pid_t(arguments[index + 1]), pid > 0
    else { return }
    let deadline = Date().addingTimeInterval(handOverDeadline)
    while kill(pid, 0) == 0 || errno == EPERM, Date() < deadline {
      usleep(50_000)
    }
  }

  // MARK: - Steps

  private static func download(_ url: URL, to destination: URL) async throws {
    do {
      let (file, response) = try await URLSession.shared.download(from: url)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else { throw Failure.download("GitHub answered \(status).") }
      try FileManager.default.moveItem(at: file, to: destination)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.download(error.localizedDescription)
    }
  }

  private static func expectedDigest(from url: URL) async throws -> String {
    let data: Data
    do {
      let (body, response) = try await URLSession.shared.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.checksum }
      data = body
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.download(error.localizedDescription)
    }
    guard let digest = checksum(in: String(decoding: data, as: UTF8.self)) else { throw Failure.checksum }
    return digest
  }

  /// The hex digest from a `shasum` line: "<hex>  Boltty.dmg".
  static func checksum(in text: String) -> String? {
    guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
    let hex = first.lowercased()
    guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
    return hex
  }

  private static func digest(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func verifySignature(of app: URL) throws {
    var running: SecCode?
    var runningStatic: SecStaticCode?
    var requirement: SecRequirement?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
          SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
          SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess,
          let requirement
    else { throw Failure.signature("this copy has no requirement to match") }
    var candidate: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
      throw Failure.signature("unreadable")
    }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
    guard status == errSecSuccess else {
      throw Failure.signature(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
    }
  }
}
