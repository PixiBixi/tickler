import Foundation
import Testing
@testable import TicklerCore

struct OrderedJSONTests {
    private let settings = #"""
    {
      "includeCoAuthoredBy": false,
      "permissions": {
        "allow": [
          "Bash(cat:*)",
          "Bash(gh pr view:*)"
        ],
        "deny": []
      },
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/bin/guard.sh \"$1\"",
                "timeout": 5.5
              }
            ]
          }
        ]
      },
      "tui": {},
      "companyAnnouncements": [
        "Déploiement à 14h / ne pas merger",
        "tab\there, esc \u001b, back\\slash"
      ],
      "count": -12e3,
      "nothing": null
    }
    """#

    @Test func roundTripsByteForByte() throws {
        #expect(try OrderedJSON.parse(settings).printed() == settings)
    }

    @Test func keepsKeyOrder() throws {
        guard case let .object(members) = try OrderedJSON.parse(settings) else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == [
            "includeCoAuthoredBy",
            "permissions",
            "model",
            "hooks",
            "tui",
            "companyAnnouncements",
            "count",
            "nothing",
        ])
    }

    @Test func decodesEscapes() throws {
        let value = try OrderedJSON.parse(#"{"a": "x\"y\\z\/wé😀\n"}"#)
        #expect(value["a"] == .string("x\"y\\z/wé😀\n"))
    }

    @Test func rejectsInvalidJSON() {
        for text in ["", "{", "{\"a\" 1}", "[1,]", "{\"a\": tru}", "\"unterminated", "{} extra", "{\"a\": \"\u{1}\"}"] {
            #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(text) }
        }
    }

    @Test func settingReplacesInPlaceOrAppends() throws {
        let value = try OrderedJSON.parse(#"{"a": 1, "b": 2}"#)
        #expect(value.setting("a", to: .bool(true)).printed() == "{\n  \"a\": true,\n  \"b\": 2\n}")
        #expect(value.setting("c", to: .null).printed() == "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": null\n}")
        #expect(value.removing("a").printed() == "{\n  \"b\": 2\n}")
        #expect(OrderedJSON.array([]).setting("a", to: .null) == .array([]))
    }
}
