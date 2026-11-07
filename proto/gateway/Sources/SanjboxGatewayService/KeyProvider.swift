import Foundation
import SanjboxGatewayCore

/// Poskytovatel klíčů je záměrně jen rozhraní. Skutečná Klíčenka, scopes,
/// revokace a custody jsou mimo prototyp (GUIDE §3 zakazuje čtení tajemství).
/// Implementace smí vracet pouze syntetický `ModelAPITestKey` z WP1.D3.
public protocol KeyProvider: Sendable {
    /// Vrací syntetický klíč pro operaci, nebo `nil`, když operace klíč nepotřebuje.
    /// Vrácený klíč se nikdy nezapisuje do auditu ani do popisu objektů.
    func key(for operation: GatewayOperation) -> ModelAPITestKey?
}

/// Mock poskytovatele klíčů. Drží jen syntetické laboratorní hodnoty a nikdy
/// je nevrací přes `description`; prototyp neumí číst skutečnou Klíčenku.
public struct MockKeyProvider: KeyProvider, Sendable {
    /// Syntetická hodnota pro testy; splňuje `ModelAPITestKey` a nikam se neposílá.
    public static let defaultModelKeyText = "sanjbox-test-mock000000000000"
    public static let defaultModelKey: ModelAPITestKey = {
        do {
            return try ModelAPITestKey(defaultModelKeyText)
        } catch {
            // Text je konstanta knihovny: když ho `ModelAPITestKey` odmítne, je to
            // chyba kódu, ne konfigurace. Tichý mock bez klíče by vypnul model.
            preconditionFailure("synthetic mock key text must satisfy ModelAPITestKey")
        }
    }()

    private let modelKey: ModelAPITestKey?

    public init(modelKey: ModelAPITestKey? = MockKeyProvider.defaultModelKey) {
        self.modelKey = modelKey
    }

    /// Mock bez klíče: modelové API se nesloží, požadavek se odmítne.
    public static let unavailable = MockKeyProvider(modelKey: nil)

    public func key(for operation: GatewayOperation) -> ModelAPITestKey? {
        operation == .model ? modelKey : nil
    }
}

extension MockKeyProvider: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        modelKey == nil ? "<mock key provider: model key unavailable>" : "<mock key provider: synthetic model key>"
    }
    public var debugDescription: String { description }
}
