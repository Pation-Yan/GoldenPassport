import Foundation
import Testing

/// Guards Resources/*.lproj/Localizable.strings and en.lproj/Localizable.stringsdict,
/// which build-app.sh copies into the app.
struct LocalizationTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.resources.appendingPathComponent("\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    /// English strings with a count: key → the plural forms of each of its variables.
    private func pluralTable() throws -> [String: [[String: String]]] {
        let url = Self.resources.appendingPathComponent("en.lproj/Localizable.stringsdict")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let entries = try #require(plist as? [String: [String: Any]])
        return entries.mapValues { entry in entry.values.compactMap { $0 as? [String: String] } }
    }

    private func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(@|lld|d|%)")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }
    }

    @Test func tablesShareKeysAndChineseIsIdentity() throws {
        let en = try table("en"), zh = try table("zh-Hans"), plurals = try pluralTable()
        #expect(Set(en.keys).isDisjoint(with: plurals.keys))
        #expect(Set(en.keys).union(plurals.keys) == Set(zh.keys))
        for (key, value) in zh { #expect(key == value, "zh-Hans must map \(key) to itself") }
    }

    @Test func englishKeepsFormatSpecifiers() throws {
        for (key, value) in try table("en") {
            #expect(specifiers(key) == specifiers(value), "specifiers differ for \(key)")
            #expect(!value.isEmpty)
        }
        for (key, variables) in try pluralTable() {
            #expect(!variables.isEmpty, "no plural rule for \(key)")
            for variable in variables {
                #expect(variable["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType")
                for form in ["one", "other"] {
                    let text = try #require(variable[form], "\(key) has no \(form) form")
                    #expect(specifiers(key) == specifiers(text), "specifiers differ for \(key) (\(form))")
                }
            }
        }
    }

    @Test func englishPluralsFollowTheCount() throws {
        let english = try #require(Bundle(url: Self.resources.appendingPathComponent("en.lproj")))
        let imported = english.localizedString(forKey: "成功导入 %lld 条记录", value: nil, table: nil)
        #expect(String.localizedStringWithFormat(imported, 1) == "Imported 1 account")
        #expect(String.localizedStringWithFormat(imported, 3) == "Imported 3 accounts")
    }
}
