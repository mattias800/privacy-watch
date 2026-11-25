import Foundation
import Security

/// Who signed a running process, as verified by the Security framework.
struct CodeSigner: Hashable {
    enum Kind: Hashable {
        /// Signed by Apple itself (macOS components and Apple's own apps).
        case apple
        /// Signed with an Apple-issued developer certificate (Developer ID or Mac App Store).
        case thirdParty
        /// Ad-hoc signed or unsigned: no verified developer identity.
        case unsigned
        /// The signature does not match the code. A red flag.
        case invalid
        /// The process is running but refuses signature inspection. Typical for
        /// tamper-protected security software; it means "can't verify", not "bad".
        case blocked
        /// The process could not be inspected (e.g. it exited).
        case unknown
    }

    let kind: Kind
    /// Short label for the menu, e.g. "Apple" or "Palo Alto Networks".
    let label: String
    /// Longer description for tooltips and logs.
    let detail: String

    /// Text used in notifications and the log.
    var notificationTag: String {
        switch kind {
        case .apple: return "Apple"
        case .thirdParty: return "third-party: \(label)"
        case .unsigned: return "⚠️ unsigned"
        case .invalid: return "⛔️ INVALID signature"
        case .blocked: return "can't verify: blocks inspection"
        case .unknown: return "signature unknown"
        }
    }
}

enum CodeSignatureInspector {
    /// Signature checks are cached per (pid, path); a pid reused by a new binary gets a new entry.
    private static var cache: [String: CodeSigner] = [:]
    private static let lock = NSLock()

    private static let appleRequirement: SecRequirement? = requirement("anchor apple")
    private static let developerRequirement: SecRequirement? = requirement("anchor apple generic")

    static func signer(pid: pid_t, path: String?) -> CodeSigner {
        let key = "\(pid):\(path ?? "")"
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let result = inspect(pid: pid, path: path)
        if result.kind != .unknown {
            lock.lock()
            cache[key] = result
            lock.unlock()
        }
        return result
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess ? req : nil
    }

    private static func inspect(pid: pid_t, path: String?) -> CodeSigner {
        // Prefer checking the running process (catches code modified after launch),
        // fall back to the binary on disk.
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        if pid > 0, SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode) == errSecSuccess, let dynamicCode {
            _ = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        } else if let path, path.hasPrefix("/") {
            _ = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        }
        guard let staticCode else {
            // kill(pid, 0) succeeds (or fails with EPERM) when the process still exists.
            if pid > 0, kill(pid, 0) == 0 || errno == EPERM {
                return CodeSigner(kind: .blocked, label: "Can't verify",
                                  detail: "The process blocks code signature inspection and its binary is not readable "
                                      + "(typical for tamper-protected security software)")
            }
            return CodeSigner(kind: .unknown, label: "Unknown", detail: "Could not inspect the process's code signature")
        }

        func satisfies(_ requirement: SecRequirement?) -> OSStatus {
            if let dynamicCode {
                return SecCodeCheckValidity(dynamicCode, [], requirement)
            }
            return SecStaticCodeCheckValidity(staticCode, [], requirement)
        }

        let baseValidity = satisfies(nil)
        if baseValidity == errSecCSUnsigned {
            return CodeSigner(kind: .unsigned, label: "Unsigned", detail: "Not code signed: no verified developer")
        }
        if baseValidity != errSecSuccess {
            return CodeSigner(kind: .invalid, label: "Invalid signature",
                              detail: "Code signature check failed (OSStatus \(baseValidity))")
        }

        var infoRef: CFDictionary?
        _ = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let leafSummary = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }

        if satisfies(appleRequirement) == errSecSuccess {
            return CodeSigner(kind: .apple, label: "Apple", detail: "Signed by Apple")
        }

        if satisfies(developerRequirement) == errSecSuccess, let leafSummary {
            let (label, detail) = describeDeveloper(certificate: leafSummary, teamID: teamID)
            return CodeSigner(kind: .thirdParty, label: label, detail: detail)
        }

        // Valid but not chained to Apple: ad-hoc or self-signed.
        return CodeSigner(kind: .unsigned, label: "Ad-hoc signed",
                          detail: "Ad-hoc or self-signed: no verified developer")
    }

    /// Turns "Developer ID Application: Palo Alto Networks (PXPZ95SK77)" into
    /// ("Palo Alto Networks", "Developer ID: Palo Alto Networks, team PXPZ95SK77").
    private static func describeDeveloper(certificate: String, teamID: String?) -> (String, String) {
        let team = teamID.map { ", team \($0)" } ?? ""
        if certificate.hasPrefix("Apple Mac OS Application Signing") {
            let label = teamID.map { "Mac App Store (\($0))" } ?? "Mac App Store"
            return (label, "Mac App Store app\(team)")
        }
        var name = certificate
        var kind = "Certificate"
        if let colon = certificate.range(of: ": ") {
            kind = String(certificate[..<colon.lowerBound])
                .replacingOccurrences(of: "Developer ID Application", with: "Developer ID")
            name = String(certificate[colon.upperBound...])
        }
        if let teamID, name.hasSuffix(" (\(teamID))") {
            name = String(name.dropLast(teamID.count + 3))
        }
        return (name, "\(kind): \(name)\(team)")
    }
}
