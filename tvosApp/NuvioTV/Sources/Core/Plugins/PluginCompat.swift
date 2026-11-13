import Foundation
import JavaScriptCore
import CommonCrypto
import CryptoKit
import SwiftSoup

/// Natives behind the Android-compatible parts of the plugin environment:
/// cheerio (a jsoup-backed DOM on Android, SwiftSoup here, so selectors and
/// `text()` behave the same), `require()` libraries, and WebCrypto AES/PBKDF2.
enum PluginCompatNatives {
    static func install(on native: JSValue, dom: PluginDOMStore) {
        func set(_ name: String, _ block: Any) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let domLoad: @convention(block) (JSValue) -> String = { html in
            dom.load(html.toString() ?? "")
        }
        let domSelect: @convention(block) (JSValue, JSValue) -> String = { doc, selector in
            dom.select(doc.toString() ?? "", selector.toString() ?? "")
        }
        let domFind: @convention(block) (JSValue, JSValue) -> String = { id, selector in
            dom.select(id.toString() ?? "", selector.toString() ?? "")
        }
        let domChildren: @convention(block) (JSValue, JSValue) -> String = { id, selector in
            dom.children(id.toString() ?? "", selector: selector.toString() ?? "")
        }
        let domParents: @convention(block) (JSValue, JSValue) -> String = { id, selector in
            dom.parents(id.toString() ?? "", selector: selector.toString() ?? "")
        }
        let domSiblings: @convention(block) (JSValue, JSValue) -> String = { id, selector in
            dom.siblings(id.toString() ?? "", selector: selector.toString() ?? "")
        }
        let domParent: @convention(block) (JSValue) -> String = { id in
            dom.parent(id.toString() ?? "")
        }
        let domClosest: @convention(block) (JSValue, JSValue) -> String = { id, selector in
            dom.closest(id.toString() ?? "", selector: selector.toString() ?? "")
        }
        let domIs: @convention(block) (JSValue, JSValue) -> Bool = { id, selector in
            dom.matches(id.toString() ?? "", selector: selector.toString() ?? "")
        }
        let domNext: @convention(block) (JSValue) -> String = { id in
            dom.sibling(id.toString() ?? "", next: true)
        }
        let domPrev: @convention(block) (JSValue) -> String = { id in
            dom.sibling(id.toString() ?? "", next: false)
        }
        let domText: @convention(block) (JSValue) -> String = { ids in
            dom.text((ids.toString() ?? "").split(separator: ",").map(String.init))
        }
        let domHtml: @convention(block) (JSValue) -> String = { id in
            dom.innerHTML(id.toString() ?? "")
        }
        let domOuterHtml: @convention(block) (JSValue) -> String = { id in
            dom.outerHTML(id.toString() ?? "")
        }
        let domAttr: @convention(block) (JSValue, JSValue) -> String = { id, name in
            dom.attribute(id.toString() ?? "", name: name.toString() ?? "")
        }
        let moduleSource: @convention(block) (JSValue) -> String = { name in
            PluginLibraries.source(named: name.toString() ?? "") ?? "throw new Error('Unknown module');"
        }
        let aes: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> String = { encrypt, mode, key, iv, data in
            PluginCrypto.aes(
                encrypt: encrypt.toBool(),
                mode: mode.toString() ?? "",
                key: Data(base64Encoded: key.toString() ?? "") ?? Data(),
                iv: Data(base64Encoded: iv.toString() ?? "") ?? Data(),
                data: Data(base64Encoded: data.toString() ?? "") ?? Data()
            )
        }
        let pbkdf2: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue) -> String = { password, salt, iterations, bits, hash in
            PluginCrypto.pbkdf2(
                password: Data(base64Encoded: password.toString() ?? "") ?? Data(),
                salt: Data(base64Encoded: salt.toString() ?? "") ?? Data(),
                iterations: Int(iterations.toInt32()),
                bits: Int(bits.toInt32()),
                hash: hash.toString() ?? "SHA-256"
            )
        }

        set("domLoad", unsafeBitCast(domLoad, to: AnyObject.self))
        set("domSelect", unsafeBitCast(domSelect, to: AnyObject.self))
        set("domFind", unsafeBitCast(domFind, to: AnyObject.self))
        set("domChildren", unsafeBitCast(domChildren, to: AnyObject.self))
        set("domParents", unsafeBitCast(domParents, to: AnyObject.self))
        set("domSiblings", unsafeBitCast(domSiblings, to: AnyObject.self))
        set("domParent", unsafeBitCast(domParent, to: AnyObject.self))
        set("domClosest", unsafeBitCast(domClosest, to: AnyObject.self))
        set("domIs", unsafeBitCast(domIs, to: AnyObject.self))
        set("domNext", unsafeBitCast(domNext, to: AnyObject.self))
        set("domPrev", unsafeBitCast(domPrev, to: AnyObject.self))
        set("domText", unsafeBitCast(domText, to: AnyObject.self))
        set("domHtml", unsafeBitCast(domHtml, to: AnyObject.self))
        set("domOuterHtml", unsafeBitCast(domOuterHtml, to: AnyObject.self))
        set("domAttr", unsafeBitCast(domAttr, to: AnyObject.self))
        set("moduleSource", unsafeBitCast(moduleSource, to: AnyObject.self))
        set("aes", unsafeBitCast(aes, to: AnyObject.self))
        set("pbkdf2", unsafeBitCast(pbkdf2, to: AnyObject.self))
    }
}

/// Parsed documents and elements of one plugin call, addressed by string ids
/// (`d1`, `d1:7`) the JavaScript side passes back. Like Android, only the last
/// few documents are kept, so a plugin parsing many pages stays small.
final class PluginDOMStore {
    static let maxDocuments = 8
    private static let none = "__NONE__"

    private var documents: [String: SwiftSoup.Document] = [:]
    private var documentOrder: [String] = []
    private var elements: [String: SwiftSoup.Element] = [:]
    private var documentCounter = 0
    private var elementCounter = 0

    func load(_ html: String) -> String {
        documentCounter += 1
        let id = "d\(documentCounter)"
        let document = (try? SwiftSoup.parse(html)) ?? SwiftSoup.Document("")
        documents[id] = document
        documentOrder.append(id)
        if documentOrder.count > Self.maxDocuments {
            let evicted = documentOrder.removeFirst()
            documents[evicted] = nil
            elements = elements.filter { !$0.key.hasPrefix(evicted + ":") }
        }
        return id
    }

    /// `$(selector)` on a document id, or `.find(selector)` on an element id.
    func select(_ id: String, _ selector: String) -> String {
        guard let root = node(id), !selector.isEmpty,
              let found = try? root.select(selector) else { return "[]" }
        return register(found.array(), in: id)
    }

    func children(_ id: String, selector: String) -> String {
        guard let element = node(id) else { return "[]" }
        let kids = element.children().array().filter { selector.isEmpty || matches($0, selector) }
        return register(kids, in: id)
    }

    func parents(_ id: String, selector: String) -> String {
        guard var current = node(id)?.parent() else { return "[]" }
        var found: [SwiftSoup.Element] = []
        while !(current is SwiftSoup.Document) {
            if selector.isEmpty || matches(current, selector) { found.append(current) }
            guard let next = current.parent() else { break }
            current = next
        }
        return register(found, in: id)
    }

    func siblings(_ id: String, selector: String) -> String {
        guard let element = node(id), let parent = element.parent() else { return "[]" }
        let others = parent.children().array().filter { $0 !== element && (selector.isEmpty || matches($0, selector)) }
        return register(others, in: id)
    }

    func parent(_ id: String) -> String {
        guard let parent = node(id)?.parent(), !(parent is SwiftSoup.Document) else { return Self.none }
        return registerOne(parent, in: id)
    }

    func closest(_ id: String, selector: String) -> String {
        var current = node(id)
        while let element = current, !(element is SwiftSoup.Document) {
            if matches(element, selector) { return registerOne(element, in: id) }
            current = element.parent()
        }
        return Self.none
    }

    func matches(_ id: String, selector: String) -> Bool {
        guard let element = node(id) else { return false }
        return matches(element, selector)
    }

    func sibling(_ id: String, next: Bool) -> String {
        guard let element = node(id),
              let sibling = try? (next ? element.nextElementSibling() : element.previousElementSibling()) else {
            return Self.none
        }
        return registerOne(sibling, in: id)
    }

    /// Text of each element (jsoup rules: whitespace normalised), joined by a
    /// space as on Android.
    func text(_ ids: [String]) -> String {
        ids.compactMap { node($0).flatMap { try? $0.text() } }.joined(separator: " ")
    }

    func innerHTML(_ id: String) -> String {
        guard let element = node(id) else { return "" }
        return (try? element.html()) ?? ""
    }

    func outerHTML(_ id: String) -> String {
        guard let element = node(id) else { return "" }
        if let document = element as? SwiftSoup.Document { return (try? document.html()) ?? "" }
        return (try? element.outerHtml()) ?? ""
    }

    /// The attribute, or `__UNDEFINED__` when it is missing or empty (Android).
    func attribute(_ id: String, name: String) -> String {
        guard let element = node(id), element.hasAttr(name),
              let value = try? element.attr(name), !value.isEmpty else { return "__UNDEFINED__" }
        return value
    }

    // MARK: - Internals

    private func node(_ id: String) -> SwiftSoup.Element? {
        if let document = documents[id] { return document }
        return elements[id]
    }

    private func matches(_ element: SwiftSoup.Element, _ selector: String) -> Bool {
        guard !selector.isEmpty else { return false }
        return (try? element.iS(selector)) ?? false
    }

    private func documentID(of id: String) -> String {
        String(id.split(separator: ":").first ?? Substring(id))
    }

    private func registerOne(_ element: SwiftSoup.Element, in contextID: String) -> String {
        if let document = element as? SwiftSoup.Document,
           let id = documents.first(where: { $0.value === document })?.key { return id }
        elementCounter += 1
        let id = "\(documentID(of: contextID)):\(elementCounter)"
        elements[id] = element
        return id
    }

    private func register(_ found: [SwiftSoup.Element], in contextID: String) -> String {
        let ids = found.map { registerOne($0, in: contextID) }
        guard let data = try? JSONSerialization.data(withJSONObject: ids),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

/// AES and PBKDF2 for `crypto.subtle`. Results are base64; a failure is
/// `"!" + reason`, which the JavaScript side turns into an OperationError.
enum PluginCrypto {
    static func aes(encrypt: Bool, mode: String, key: Data, iv: Data, data: Data) -> String {
        switch mode {
        case "AES-GCM":
            return gcm(encrypt: encrypt, key: key, iv: iv, data: data)
        case "AES-CBC", "AES-ECB":
            return commonCrypto(encrypt: encrypt, ecb: mode == "AES-ECB", key: key, iv: iv, data: data)
        default:
            return "!Unsupported algorithm: \(mode)"
        }
    }

    private static func gcm(encrypt: Bool, key: Data, iv: Data, data: Data) -> String {
        do {
            let symmetricKey = SymmetricKey(data: key)
            let nonce = try AES.GCM.Nonce(data: iv)
            if encrypt {
                let box = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)
                return (box.ciphertext + box.tag).base64EncodedString()
            }
            guard data.count >= 16 else { return "!The data is too short." }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
            return try AES.GCM.open(box, using: symmetricKey).base64EncodedString()
        } catch {
            return "!\(error.localizedDescription)"
        }
    }

    private static func commonCrypto(encrypt: Bool, ecb: Bool, key: Data, iv: Data, data: Data) -> String {
        guard [16, 24, 32].contains(key.count) else { return "!Invalid AES key length." }
        guard ecb || iv.count == kCCBlockSizeAES128 else { return "!The IV must be 16 bytes." }
        var options = CCOptions(kCCOptionPKCS7Padding)
        if ecb { options |= CCOptions(kCCOptionECBMode) }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress, key.count,
                            ecb ? nil : ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outputBytes.baseAddress, outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return "!AES failed (\(status))." }
        return output.prefix(written).base64EncodedString()
    }

    static func pbkdf2(password: Data, salt: Data, iterations: Int, bits: Int, hash: String) -> String {
        let prf: CCPseudoRandomAlgorithm
        switch hash {
        case "SHA-1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case "SHA-384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "SHA-512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }
        let length = max(1, bits / 8)
        guard iterations > 0, length <= 1024 else { return "!Invalid PBKDF2 parameters." }
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf,
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), length
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return "!PBKDF2 failed (\(status))." }
        return derived.base64EncodedString()
    }
}
