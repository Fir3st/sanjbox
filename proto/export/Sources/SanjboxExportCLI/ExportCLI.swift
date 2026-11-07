import Foundation
import SanjboxExport

/// Exit kódy CLI. Jsou součástí dokumentovaného rozhraní (README).
public enum ExportExitCode: Int32, Sendable {
    /// Plán je čistý a (u `--apply`) všechny soubory zkopírované a zkaranténěné.
    case ok = 0
    /// I/O chyba, TOCTOU, selhání karantény. Nic se nedá považovat za úspěch.
    case failure = 1
    /// Chybná příkazová řádka.
    case usage = 2
    /// Selekce odmítla aspoň jednu cestu. `--apply` se v takovém případě neprovede.
    case policyRejection = 3
}

/// Argumenty `sanjbox-export` po rozboru.
public struct ExportArguments: Sendable, Equatable {
    public var rootPath: String
    public var destinationRoot: String?
    public var relativePaths: [String]
    public var apply: Bool
    public var auditPath: String?

    public init(
        rootPath: String,
        destinationRoot: String? = nil,
        relativePaths: [String],
        apply: Bool = false,
        auditPath: String? = nil
    ) {
        self.rootPath = rootPath
        self.destinationRoot = destinationRoot
        self.relativePaths = relativePaths
        self.apply = apply
        self.auditPath = auditPath
    }
}

public enum ExportArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case missingRoot
    case missingFiles
    case applyWithoutDestination

    public var description: String {
        switch self {
        case let .unknownOption(option): return "unknown option: \(option)"
        case let .missingValue(option): return "missing value for \(option)"
        case .missingRoot: return "--root <dir> is required"
        case .missingFiles: return "at least one --file <relative path> is required"
        case .applyWithoutDestination: return "--apply requires --dest <dir>"
        }
    }
}

public enum ExportArgumentParser {
    /// Rozbor argumentů bez přístupu k souborovému systému. `--dry-run` je výchozí režim,
    /// `--apply` ho vypne; oba příznaky najednou jsou chyba.
    public static func parse(_ arguments: [String]) throws -> ExportArguments {
        var root: String?
        var destination: String?
        var files: [String] = []
        var apply = false
        var dryRun = false
        var audit: String?

        var index = 0
        func nextValue(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ExportArgumentError.missingValue(option) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--root": root = try nextValue(argument)
            case "--dest": destination = try nextValue(argument)
            case "--file": files.append(try nextValue(argument))
            case "--audit": audit = try nextValue(argument)
            case "--apply": apply = true
            case "--dry-run": dryRun = true
            default: throw ExportArgumentError.unknownOption(argument)
            }
            index += 1
        }

        if apply && dryRun {
            throw ExportArgumentError.unknownOption("--apply together with --dry-run")
        }
        guard let root else { throw ExportArgumentError.missingRoot }
        guard !files.isEmpty else { throw ExportArgumentError.missingFiles }
        if apply && destination == nil { throw ExportArgumentError.applyWithoutDestination }

        return ExportArguments(
            rootPath: root,
            destinationRoot: destination,
            relativePaths: files,
            apply: apply,
            auditPath: audit
        )
    }
}

public struct ExportCLI: Sendable {
    public init() {}

    public static let usage = """
        usage: sanjbox-export --root <dir> --file <relative path> [--file ...]
                              [--dest <dir>] [--apply] [--audit <file>]

        Fáze 1–2 (selekce a preview) běží vždy a nic nezapisují. `--apply` navíc
        zkopíruje přijaté soubory do nového cílového stromu a nastaví
        com.apple.quarantine. Bez `--apply` jde o dry-run. `--audit` zapisuje
        append-only JSONL jen s `--apply`; v dry-runu jde jen na stdout.
        `--dest` nesmí ležet uvnitř `--root`.

        exit 0  plán je čistý; u --apply vše zkopírováno a zkaranténěno
        exit 1  I/O chyba, TOCTOU (soubor se změnil), karanténu nelze nastavit
        exit 2  chybná příkazová řádka
        exit 3  selekce odmítla aspoň jednu cestu (apply se neprovede)
        """

    /// Spustí CLI. Výstup jde do dodaných zapisovačů, takže testy vidí přesně to,
    /// co by uživatel dostal na stdout/stderr.
    public func run(
        arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            stdout(ExportCLI.usage + "\n")
            return ExportExitCode.ok.rawValue
        }

        let parsed: ExportArguments
        do {
            parsed = try ExportArgumentParser.parse(arguments)
        } catch {
            stderr("sanjbox-export: \(error)\n\n\(ExportCLI.usage)\n")
            return ExportExitCode.usage.rawValue
        }

        // Cíl uvnitř zdroje by zapisoval do právě exportovaného stromu. Odmítáme
        // ještě před vytvořením auditního souboru, aby dry-run nic nevedl jako side effect.
        if let destination = parsed.destinationRoot,
           ExportPathPolicy.isDestination(destination, insideRoot: parsed.rootPath) {
            stderr("sanjbox-export: --dest \(destination) is inside --root \(parsed.rootPath)\n\n\(ExportCLI.usage)\n")
            return ExportExitCode.usage.rawValue
        }

        let recording = RecordingAuditSink()
        do {
            // U apply+--audit jde audit na disk append-only hned od prvního záznamu.
            // Dry-run nikdy nezapisuje: audit jde jen na stdout.
            let auditSink: any AuditSink
            if parsed.apply, let auditPath = parsed.auditPath {
                auditSink = try FileAuditSink(path: auditPath)
            } else {
                auditSink = recording
            }

            let plan = try ExportPreparer(rootPath: parsed.rootPath)
                .prepare(relativePaths: parsed.relativePaths, audit: auditSink)
            stdout(try plan.jsonString() + "\n")

            if !parsed.apply, parsed.auditPath != nil {
                // Dry-run --audit: dokument existuje jen na stdout, na disku nic nevzniká.
                stdout(try recording.documentString())
            }

            if parsed.apply {
                guard plan.isClean else {
                    stderr("sanjbox-export: selection rejected \(plan.rejectedPaths.joined(separator: ", ")); refusing to copy\n")
                    return ExportExitCode.policyRejection.rawValue
                }
                guard let destination = parsed.destinationRoot else {
                    throw ExportArgumentError.applyWithoutDestination
                }
                do {
                    let exported = try ExportCopier().apply(plan, destinationRoot: destination, audit: auditSink)
                    stdout(String(decoding: try exported.jsonData(), as: UTF8.self) + "\n")
                } catch {
                    stderr("sanjbox-export: export failed: \(error)\n")
                    // Záznamy už jsou v append-only auditu; úspěch to není.
                    return ExportExitCode.failure.rawValue
                }
            }

            return (plan.isClean ? ExportExitCode.ok : .policyRejection).rawValue
        } catch {
            stderr("sanjbox-export: \(error)\n")
            return ExportExitCode.failure.rawValue
        }
    }
}
