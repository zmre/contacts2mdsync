import Contacts
import CoreGraphics
import Foundation
import ImageIO

/// One comparable value of a scratch card: a field, the labeled-value
/// identifier (or a positional key for single-valued fields), label, value.
/// Only ever built from harness cards, so printing values is fine.
struct FieldRow: Codable, Equatable {
    var field: String
    var key: String
    var label: String?
    var value: String
}

enum Snapshot {
    /// Keys `rows(of:)` reads. Deliberately excludes CNContactNoteKey.
    nonisolated(unsafe) static let keys: [any CNKeyDescriptor] = [
        CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
        CNContactNameSuffixKey, CNContactNicknameKey, CNContactPhoneticGivenNameKey,
        CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactUrlAddressesKey,
        CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactDatesKey,
        CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey, CNContactRelationsKey,
        CNContactImageDataKey, CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey,
    ].map { $0 as any CNKeyDescriptor }

    static func rows(of c: CNContact) -> [FieldRow] {
        var rows: [FieldRow] = []
        func single(_ field: String, _ value: String) {
            if !value.isEmpty { rows.append(FieldRow(field: field, key: "-", label: nil, value: value)) }
        }
        func multi<T>(_ field: String, _ values: [CNLabeledValue<T>], _ render: (T) -> String) {
            for lv in values {
                rows.append(FieldRow(field: field, key: lv.identifier, label: lv.label, value: render(lv.value)))
            }
        }
        single("namePrefix", c.namePrefix)
        single("givenName", c.givenName)
        single("middleName", c.middleName)
        single("familyName", c.familyName)
        single("nameSuffix", c.nameSuffix)
        single("nickname", c.nickname)
        single("phoneticGivenName", c.phoneticGivenName)
        single("organization", c.organizationName)
        single("department", c.departmentName)
        single("jobTitle", c.jobTitle)
        multi("phone", c.phoneNumbers) { $0.stringValue }
        multi("email", c.emailAddresses) { $0 as String }
        multi("url", c.urlAddresses) { $0 as String }
        multi("address", c.postalAddresses) { render(address: $0) }
        if let birthday = c.birthday { single("birthday", render(date: birthday)) }
        multi("date", c.dates) { render(date: $0 as DateComponents) }
        multi("social", c.socialProfiles) {
            "service=\($0.service) user=\($0.username) url=\($0.urlString) uid=\($0.userIdentifier)"
        }
        multi("im", c.instantMessageAddresses) { "service=\($0.service) user=\($0.username)" }
        multi("relation", c.contactRelations) { $0.name }
        single("imageDataAvailable", c.imageDataAvailable ? "yes" : "no")
        if let data = c.imageData { single("image", describe(image: data)) }
        if let thumb = c.thumbnailImageData { single("thumbnail", describe(image: thumb)) }
        return rows
    }

    static func render(address a: CNPostalAddress) -> String {
        [
            ("street", a.street), ("subLocality", a.subLocality), ("city", a.city),
            ("subAdminArea", a.subAdministrativeArea), ("state", a.state), ("postalCode", a.postalCode),
            ("country", a.country), ("iso", a.isoCountryCode),
        ].filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    static func render(date d: DateComponents) -> String {
        let year = d.year.map { String(format: "%04d", $0) } ?? "----"
        let month = d.month.map { String(format: "%02d", $0) } ?? "--"
        let day = d.day.map { String(format: "%02d", $0) } ?? "--"
        let cal = d.calendar.map { " cal=\($0.identifier)" } ?? ""
        return "\(year)-\(month)-\(day)\(cal)"
    }

    static func describe(image data: Data) -> String {
        let format: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            format = "png"
        } else if data.starts(with: [0xFF, 0xD8]) {
            format = "jpeg"
        } else if data.count > 12, data[4..<12].elementsEqual("ftypheic".utf8) {
            format = "heic"
        } else {
            format = "other"
        }
        var dims = "?x?"
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        {
            dims = "\(w)x\(h)"
        }
        return "\(format) \(dims) \(data.count)B sha=\(sha256Hex(data).prefix(12))"
    }

    /// A deterministic 256x256 PNG (diagonal gradient + square) for image round-trips.
    static func makeTestPNG() throws -> Data {
        let size = 256
        guard
            let ctx = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SpikeError("CGContext failed") }
        for y in 0..<size {
            for x in stride(from: 0, to: size, by: 8) {
                ctx.setFillColor(
                    CGColor(
                        red: CGFloat(x) / CGFloat(size), green: CGFloat(y) / CGFloat(size), blue: 0.6, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 1))
            }
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 96, y: 96, width: 64, height: 64))
        guard let image = ctx.makeImage() else { throw SpikeError("makeImage failed") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)
        else { throw SpikeError("CGImageDestination failed") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SpikeError("PNG encode failed") }
        return out as Data
    }
}

/// Aligns two row lists per field: same labeled-value id first, then by order.
struct RowDiff {
    var field: String
    var before: FieldRow?
    var after: FieldRow?

    var idStable: String {
        guard let before, let after else { return "-" }
        if before.key == "-" { return "n/a" }
        return before.key == after.key ? "same" : "changed"
    }

    var changed: Bool { before?.label != after?.label || before?.value != after?.value }

    static func align(_ before: [FieldRow], _ after: [FieldRow]) -> [RowDiff] {
        var fields: [String] = []
        for row in before + after where !fields.contains(row.field) { fields.append(row.field) }
        var out: [RowDiff] = []
        for field in fields {
            var b = before.filter { $0.field == field }
            var a = after.filter { $0.field == field }
            // Pass 1: identical labeled-value identifiers.
            for row in b where row.key != "-" {
                if let idx = a.firstIndex(where: { $0.key == row.key }) {
                    out.append(RowDiff(field: field, before: row, after: a.remove(at: idx)))
                    b.removeAll { $0 == row }
                }
            }
            // Pass 2: positional.
            while !b.isEmpty || !a.isEmpty {
                out.append(
                    RowDiff(
                        field: field, before: b.isEmpty ? nil : b.removeFirst(),
                        after: a.isEmpty ? nil : a.removeFirst()))
            }
        }
        return out
    }
}
