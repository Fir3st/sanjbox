import Darwin
import Foundation

/// Rozhraní k souborovým systémovým voláním, která musí být TOCTOU-safe.
///
/// Zásady:
/// - kořen se otevře jednou jako fd a všechny relativní cesty se otevírají přes `openat`,
/// - žádná komponenta se neotevírá přes `O_NOFOLLOW`-obejití, `..` se nikdy neposílá do jádra,
/// - typ souboru se zjišťuje `fstatat(AT_SYMLINK_NOFOLLOW)` **před** otevřením, aby se FIFO
///   nebo zařízení vůbec neotevřelo,
/// - autoritativní metadata jsou z `fstat` na otevřeném fd, ne z cesty.
enum SafePath {
    struct Rejection: Error, Equatable {
        var reason: SelectionReason
        var detail: String?
    }

    /// Otevře kořen exportu. Symlink v cestě ke kořeni je povolený (např. `/tmp` →
    /// `/private/tmp`); rozhoduje fd, se kterým se dál pracuje.
    static func openRoot(_ path: String) -> Result<Int32, ExportError> {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            return .failure(.invalidRoot(path: path, errno: errno))
        }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            let code = errno
            close(fd)
            return .failure(.invalidRoot(path: path, errno: code))
        }
        guard FileKind(mode: status.st_mode) == .directory else {
            close(fd)
            return .failure(.invalidRoot(path: path, errno: ENOTDIR))
        }
        return .success(fd)
    }

    /// Projde všechny komponenty kromě poslední a vrátí fd každého otevřeného adresáře
    /// (volající je zavírá) plus jméno poslední komponenty.
    static func openDirectoryChain(
        rootFD: Int32,
        components: [String]
    ) -> Result<(opened: [Int32], name: String), Rejection> {
        guard let name = components.last else {
            return .failure(Rejection(reason: .ioError, detail: "empty relative path"))
        }
        var opened: [Int32] = []
        var currentFD = rootFD
        for component in components.dropLast() {
            // Klasifikace před otevřením: `openat` na symlink s `O_DIRECTORY|O_NOFOLLOW`
            // hlásí `ENOTDIR`, což by symlink zaměnilo za „není adresář“. Rozhoduje fstatat.
            var status = stat()
            guard component.withCString({ fstatat(currentFD, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                let code = errno
                for openedFD in opened.reversed() { close(openedFD) }
                return .failure(rejection(errno: code, component: component, operation: "fstatat"))
            }
            let incoming = FileKind(mode: status.st_mode)
            guard incoming == .directory else {
                for openedFD in opened.reversed() { close(openedFD) }
                return .failure(rejection(kind: incoming, component: component))
            }
            let fd = component.withCString { openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else {
                let code = errno
                for openedFD in opened.reversed() { close(openedFD) }
                return .failure(rejection(errno: code, component: component, operation: "openat"))
            }
            opened.append(fd)
            currentFD = fd
        }
        return .success((opened, name))
    }

    /// Metadata poslední komponenty bez otevření souboru (`AT_SYMLINK_NOFOLLOW`).
    static func inspect(parentFD: Int32, name: String) -> Result<FileSnapshot, Rejection> {
        var status = stat()
        let result = name.withCString { fstatat(parentFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else {
            return .failure(rejection(errno: errno, component: name, operation: "fstatat"))
        }
        let kind = FileKind(mode: status.st_mode)
        guard kind == .regular else {
            return .failure(rejection(kind: kind, component: name))
        }
        guard status.st_nlink <= 1 else {
            return .failure(Rejection(reason: .hardlink, detail: "nlink=\(status.st_nlink) at \(name)"))
        }
        return .success(FileSnapshot(fromStat: status))
    }

    /// Otevře soubor pro kopii: klasifikace předem, `O_NOFOLLOW`, autoritativní `fstat` na fd.
    /// `O_NONBLOCK` a `O_NOCTTY` jsou pojistka pro případ, že by klasifikace byla v rozporu
    /// se skutečností (FIFO by jinak blokovalo `open`).
    static func openForCopy(parentFD: Int32, name: String) -> Result<(fd: Int32, snapshot: FileSnapshot), Rejection> {
        switch inspect(parentFD: parentFD, name: name) {
        case let .failure(rejection):
            return .failure(rejection)
        case let .success(expected):
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
            let fd = name.withCString { openat(parentFD, $0, flags) }
            guard fd >= 0 else {
                return .failure(rejection(errno: errno, component: name, operation: "openat"))
            }
            var status = stat()
            guard fstat(fd, &status) == 0 else {
                let code = errno
                close(fd)
                return .failure(rejection(errno: code, component: name, operation: "fstat"))
            }
            let kind = FileKind(mode: status.st_mode)
            guard kind == .regular else {
                close(fd)
                return .failure(rejection(kind: kind, component: name))
            }
            let snapshot = FileSnapshot(fromStat: status)
            guard snapshot.linkCount <= 1 else {
                close(fd)
                return .failure(Rejection(reason: .hardlink, detail: "nlink=\(snapshot.linkCount) at \(name)"))
            }
            guard snapshot.matchesIdentity(expected) else {
                close(fd)
                return .failure(
                    Rejection(
                        reason: .ioError,
                        detail: "changed between classification and open at \(name)"
                    )
                )
            }
            return .success((fd, snapshot))
        }
    }

    static func rejection(errno code: Int32, component: String, operation: String) -> Rejection {
        switch code {
        case ELOOP:
            return Rejection(reason: .symlink, detail: "symlink component '\(component)'")
        case ENOENT, ENOTDIR:
            return code == ENOENT
                ? Rejection(reason: .missing, detail: "'\(component)' does not exist")
                : Rejection(reason: .notRegularFile, detail: "'\(component)' is not a directory")
        case EACCES, EPERM:
            return Rejection(reason: .ioError, detail: "\(operation) \(component): permission denied")
        default:
            return Rejection(reason: .ioError, detail: "\(operation) \(component): \(SyscallErrorText.text(code))")
        }
    }

    static func rejection(kind: FileKind, component: String) -> Rejection {
        switch kind {
        case .symlink:
            return Rejection(reason: .symlink, detail: "'\(component)' is a symlink")
        case .directory:
            return Rejection(reason: .notRegularFile, detail: "'\(component)' is a directory")
        case .fifo, .socket, .characterDevice, .blockDevice:
            return Rejection(reason: .specialFile, detail: "'\(component)' is a \(kind.rawValue)")
        case .regular:
            return Rejection(reason: .ioError, detail: "'\(component)' rejected")
        case .unknown:
            return Rejection(reason: .specialFile, detail: "'\(component)' has unknown file type")
        }
    }
}
