import Foundation
import Network
import Security

/// Explicit server identity supplied by the trusted owner. No Keychain lookup,
/// trust-store installation, certificate generation or TLS verification bypass.
@MainActor public struct GatewayTLSConfiguration {
    private let identity: sec_identity_t
    public init(identity: SecIdentity) throws {
        guard let value = sec_identity_create(identity) else { throw ModelAPIFailure.configuration }
        self.identity = value
    }
    public init(pkcs12: Data, passphrase: String) throws {
        guard pkcs12.count <= 65_536 else { throw ModelAPIFailure.limit }
        var items: CFArray?
        let options: [CFString: Any] = [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true]
        guard SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let records = items as? [[String: Any]], records.count == 1,
              let value = records[0][kSecImportItemIdentity as String] else { throw ModelAPIFailure.configuration }
        try self.init(identity: value as! SecIdentity)
    }
    func parameters() -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_tls_resumption_enabled(options.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(options.securityProtocolOptions, false)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
}
