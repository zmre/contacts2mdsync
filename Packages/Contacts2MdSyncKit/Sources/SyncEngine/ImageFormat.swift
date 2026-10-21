internal import Foundation

/// Sniffs image bytes for the sidecar file extension.
enum ImageFormat {
    /// `jpg`, `png`, `heic`, `gif`, `tiff`, else `jpg` (Apple stores JPEG by default).
    static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "mif1", "heis"].contains(brand) { return "heic" }
        }
        return "jpg"
    }
}
