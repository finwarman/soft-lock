import Foundation
import CryptoKit

final class PinStore {
    private struct Credential: Codable {
        let salt: Data
        let digest: Data
    }

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func save(_ pin: String) throws {
        let salt = Data(UUID().uuidString.utf8)
        let credential = Credential(salt: salt, digest: digest(pin, salt: salt))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(credential)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func matches(_ pin: String) throws -> Bool {
        let credential = try JSONDecoder().decode(Credential.self, from: Data(contentsOf: url))
        return digest(pin, salt: credential.salt) == credential.digest
    }

    private func digest(_ pin: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
