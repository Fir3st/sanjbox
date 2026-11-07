import Darwin
import Foundation

/// Identita a metadata souboru tak, jak je viděla fáze preview.
///
/// Fáze kopie otevře soubor znovu přes `openat(O_NOFOLLOW)`, udělá `fstat` na fd
/// a porovná tento snapshot. Rozdíl znamená výměnu souboru mezi preview a kopií
/// a export skončí chybou.
public struct FileSnapshot: Codable, Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Přístupová práva včetně setuid/setgid/sticky (`st_mode & 0o7777`).
    public let mode: UInt16
    public let linkCount: UInt64

    public init(device: UInt64, inode: UInt64, size: Int64, mode: UInt16, linkCount: UInt64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mode = mode
        self.linkCount = linkCount
    }

    init(fromStat status: stat) {
        self.device = UInt64(bitPattern: Int64(status.st_dev))
        self.inode = UInt64(status.st_ino)
        self.size = Int64(status.st_size)
        self.mode = UInt16(status.st_mode & 0o7777)
        self.linkCount = UInt64(status.st_nlink)
    }

    /// Porovnává jen to, co určuje identitu a velikost souboru — ne práva.
    /// Změna práv mezi preview a kopií není výměna inode; kopie práva stejně bere z fd.
    public func matchesIdentity(_ other: FileSnapshot) -> Bool {
        device == other.device && inode == other.inode && size == other.size && linkCount == other.linkCount
    }
}

/// Typ souboru z `st_mode`, jen v rozsahu, který export rozlišuje.
public enum FileKind: String, Codable, Sendable {
    case regular
    case directory
    case symlink
    case fifo
    case socket
    case characterDevice
    case blockDevice
    case unknown

    init(mode: mode_t) {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): self = .regular
        case mode_t(S_IFDIR): self = .directory
        case mode_t(S_IFLNK): self = .symlink
        case mode_t(S_IFIFO): self = .fifo
        case mode_t(S_IFSOCK): self = .socket
        case mode_t(S_IFCHR): self = .characterDevice
        case mode_t(S_IFBLK): self = .blockDevice
        default: self = .unknown
        }
    }
}
