import AppKit
import Foundation

/// Whether this app may read the folders films live in.
///
/// ## Why an app has to ask
///
/// macOS protects Desktop, Documents, Downloads and removable volumes with TCC. A process
/// that has never read one of them gets a system prompt the first time it tries, and the
/// answer is remembered **for the whole app** — not per folder, and not per run. If the
/// answer is no, the access attempt fails with a permission error and the app looks broken:
/// the film will not open, the file chooser will not list it, and nothing says why.
///
/// That is the failure this type exists to make visible. Measured on the real film: launching
/// the installed copy from the Finder raised *"'60FPS' would like to access files in your
/// Desktop folder"* with no prior explanation, and a user who clicked **Don't Allow** would
/// have been left with an app that does nothing at all when asked to open a film.
///
/// ## Why it cannot be read, only tried
///
/// There is no public API for the answer. The only way to know is to attempt the access,
/// which is also the thing that raises the prompt — so a check *is* the question, and there
/// is no quiet way to ask it. Two consequences shape the UI:
///
/// - The check is run when the settings screen is opened and when the user asks for it, never
///   in the background, so a prompt is always a response to something the user did.
/// - If the answer is already **no**, macOS does not ask again. A second attempt fails
///   immediately and silently, so a row that only re-tried would be a button that does
///   nothing. `openPrivacySettings()` is the other half: the switch has to be moved by hand,
///   in System Settings, and the row says so.
enum FolderAccess {

    /// What one folder's answer was.
    enum State: Equatable, CustomStringConvertible {
        /// The directory listed. The app can read films here.
        case allowed
        /// macOS refused. It will not ask again; the switch is in System Settings.
        case refused
        /// Nobody has asked yet, so there is no answer to report.
        ///
        /// Deliberately distinct from `refused`, and the distinction is the whole reason this
        /// state exists. A check *is* the question: there is no way to read macOS's answer
        /// without attempting the access, and an attempt on a folder it has never been asked
        /// about raises a system prompt. Probing three folders to populate a status line
        /// therefore raises **three** dialogs — measured, one at a time, Desktop then
        /// Documents then Downloads — which is a settings screen that greets the user with a
        /// queue of system alerts. So the row reports what real work has already proved, calls
        /// everything else "not asked", and only asks when the user clicks.
        case notAsked
        /// Not on this machine. Nothing to ask about.
        case absent
        /// Something else went wrong. Reported rather than guessed at.
        case unknown(String)

        var description: String {
            switch self {
            case .allowed: "allowed"
            case .refused: "not allowed"
            case .notAsked: "not asked"
            case .absent: "not present"
            case .unknown(let why): "could not tell (\(why))"
            }
        }

        var isRefused: Bool { self == .refused }
    }

    struct Folder: Identifiable, Equatable {
        public let url: URL
        public let state: State
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    struct Report: Equatable {
        public let folders: [Folder]

        /// Folders macOS is refusing. Non-empty means the app cannot be relied on.
        var refused: [Folder] { folders.filter { $0.state.isRefused } }
        var allowed: [Folder] { folders.filter { $0.state == .allowed } }
        var notAsked: [Folder] { folders.filter { $0.state == .notAsked } }

        /// Nothing is being refused, so there is nothing to repair.
        var isClear: Bool { refused.isEmpty }

        /// Whether clicking the row would do something. True when a folder is refused *or*
        /// has never been asked: one needs the switch moved, the other needs the question put.
        /// A row that is clickable when everything already works teaches the user not to trust
        /// the rows that are.
        var needsAttention: Bool { !refused.isEmpty || !notAsked.isEmpty }

        /// One line for the settings row.
        ///
        /// Written as a sentence about the *app*, not a table of folders, because the only
        /// thing the user has to decide is whether to act. The per-folder detail is the
        /// second line.
        var headline: String {
            if folders.isEmpty { return "No folder to check yet" }
            if !refused.isEmpty {
                return refused.count == 1
                    ? "\(refused[0].name) is not readable"
                    : "\(refused.count) folders are not readable"
            }
            if !allowed.isEmpty {
                return allowed.count == 1
                    ? "Allowed to read \(allowed[0].name)"
                    : "Allowed to read \(allowed.count) folders"
            }
            if notAsked.count == 1 { return "Not asked about \(notAsked[0].name) yet" }
            return "Not asked yet"
        }

        /// The folders and their answers, for the second line.
        var detail: String {
            folders.map { "\($0.name): \($0.state)" }.joined(separator: "  ·  ")
        }
    }

    /// The folders a film is likely to be in, plus wherever the app is already looking.
    ///
    /// The three protected ones are named because they are the ones macOS gates. Anything the
    /// user has actually opened or queued is added, because a film on an external volume is
    /// protected too and is the case where a refusal is least obvious.
    static func standardFolders(including extra: [URL] = []) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        for url in extra {
            let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            if !urls.contains(where: { $0.path == folder.path }) { urls.append(folder) }
        }
        return urls
    }

    /// Ask macOS, by trying.
    ///
    /// **This is the access attempt.** If the app has never been given an answer for one of
    /// these folders, this call is what raises the prompt, and it blocks until the user
    /// answers it. It must therefore never be called from the main thread.
    static func state(of url: URL) -> State {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .absent
        }
        // A *file* where a folder was expected is not something to report as a permission
        // problem; listing it would fail for an unrelated reason.
        guard isDirectory.boolValue else { return .absent }

        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .allowed
        } catch let error as NSError {
            // TCC refusals arrive in one of two shapes depending on which layer notices
            // first: Cocoa's own "you do not have permission" and the POSIX error underneath
            // it. Both mean the same thing here and both are worth recognising, because a
            // refusal reported as `unknown` is a refusal the row will not offer to fix.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoPermissionError {
                return .refused
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) {
                return .refused
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EPERM) {
                return .refused
            }
            return .unknown(error.localizedDescription)
        }
    }

    /// The report, from what the app already knows. **Asks nothing and cannot prompt.**
    ///
    /// `known` is what real file operations have proved — a film that opened from this folder,
    /// or a read that was refused. Anything not in it is reported as "not asked", which is
    /// true, and is the state the row invites the user to resolve.
    static func report(known: [String: State] = [:], including extra: [URL] = []) -> Report {
        Report(folders: standardFolders(including: extra).map { url in
            Folder(url: url, state: known[url.path] ?? .notAsked)
        })
    }

    /// Ask macOS about every folder. **This is the access attempt.**
    ///
    /// It can raise one system prompt per folder it has never been answered about, and it
    /// blocks until each one is answered — so it must never be called from the main thread,
    /// and never on a screen that is merely being opened. Returns the answers, for the caller
    /// to remember.
    static func probe(including extra: [URL] = []) -> (report: Report, known: [String: State]) {
        let urls = standardFolders(including: extra)
        var known: [String: State] = [:]
        for url in urls { known[url.path] = state(of: url) }
        return (Report(folders: urls.map { Folder(url: $0, state: known[$0.path]!) }), known)
    }

    /// Classify a folder after an operation on it has already failed.
    ///
    /// Safe to call anywhere, including the main thread: the read has just been refused, so
    /// this cannot raise a prompt. It is how a failure the user actually caused — a film that
    /// will not open — turns into a recorded answer instead of a mystery.
    static func classify(afterFailureIn url: URL) -> (path: String, state: State) {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        return (folder.path, state(of: folder))
    }

    /// The pane where the switch actually lives.
    ///
    /// Two spellings, because the pane's identifier changed when System Settings replaced
    /// System Preferences and the old one is still accepted on some systems. The first that
    /// opens wins; if neither does, the caller says so rather than leaving a dead button.
    @discardableResult
    @MainActor
    static func openPrivacySettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}
