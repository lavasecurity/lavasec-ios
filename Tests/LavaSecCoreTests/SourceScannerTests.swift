import Foundation
import XCTest

@testable import LavaSecCore

/// Executable tests for the source scanner the registry pins depend on.
///
/// These matter more than they look. `SourceFileRegistryTests` asserts that no file outside the
/// registered set extends `PacketTunnelProvider` or `AppViewModel` — the check that replaced the
/// compiler's `private`/`private(set)` after the class was split across files. That check is only
/// as good as this scanner: a missed declaration form lets members sit outside every absence pin
/// while the suite stays green, and a false positive fails the build over a comment.
///
/// Both directions were found by review on PR #651 across five rounds, each time against a version
/// that looked complete. So the forms are pinned here, executably, rather than left to the next
/// reviewer.
final class SourceScannerTests: XCTestCase {
    private let names: Set<String> = ["PacketTunnelProvider"]

    // MARK: - The coverage corpus, and the ratchet over it

    /// Declaration spellings the scanner MUST find, one per construct it has to handle.
    static let spellingCorpus = [
            "extension PacketTunnelProvider {}",
            "extension  PacketTunnelProvider {}",              // more than one space
            "extension\nPacketTunnelProvider {}",              // a newline
            "extension PacketTunnelProvider{}",                // no space before the brace
            "extension PacketTunnelProvider: Equatable {}",    // conformance
            "extension PacketTunnelProvider : Equatable {}",   // space before the colon
            "extension/*note*/PacketTunnelProvider {}",        // block comment before the name
            "extension PacketTunnelProvider/*note*/ {}",       // block comment after it
            "// note\rextension PacketTunnelProvider {}",
            "// note\r\nextension PacketTunnelProvider {}",
            "extension//note\nPacketTunnelProvider {}",        // line comment before the name
            "extension /* /* nested */ */ PacketTunnelProvider {}",
            "extension PacketTunnelProvider where Self: Sendable {}",
            "extension `PacketTunnelProvider` {}",              // escaped identifier
            "extension `PacketTunnelProvider`: Equatable {}",
            "let x=4/2; extension PacketTunnelProvider { func f() { _ = 4/2 } }",
            "let x=values[0]/2; extension PacketTunnelProvider { func f() { _ = 4/2 } }",
            "let x=maybe!/2; extension PacketTunnelProvider {}; let y=4/2",
            "let x=maybe!!/2; extension PacketTunnelProvider {}; let y=4/2",
            "let x=S().yield/2; extension PacketTunnelProvider {}; let y=4/2",
            "let x=S().await/2; extension PacketTunnelProvider {}; let y=4/2",
            "let yield=4; let x=yield/2; extension PacketTunnelProvider {}; let y=4/2",
            "let x = 4\n/ 2; extension PacketTunnelProvider {}; let y=4/2",
            "let x = 4 /* nested /*\n*/ */ / 2; extension PacketTunnelProvider {}; let y=4/2",
            #"let x="x"/2; extension PacketTunnelProvider {}; let y=4/2"#,
            "let x=4/* note *//2; extension PacketTunnelProvider {}; let y=4/2",
]

    /// Text that must NOT be reported: quoted lookalikes, longer names, nested types, regex payloads.
    static let lookalikeCorpus = [
            "// extension PacketTunnelProvider is what this file does NOT do",
            "/// See `extension PacketTunnelProvider` in the provider files.",
            "/* extension PacketTunnelProvider */",
            #"let note = "extension PacketTunnelProvider""#,
            "let note = \"\"\"\nextension PacketTunnelProvider\n\"\"\"",
            ##"let note = #"extension PacketTunnelProvider"#"##,
            // The class's name as a PREFIX of another type.
            "extension PacketTunnelProviderXY: Equatable {}",
            // A NESTED type: extending it adds nothing to the class.
            "extension PacketTunnelProvider.Nested {}",
            // Swift REGEX LITERALS — the payload is not code.
            "let pattern = /extension PacketTunnelProvider/",
            "let pattern = #/extension PacketTunnelProvider/#",
            "let pattern = ##/extension PacketTunnelProvider/##",
            "func pattern() { return /extension PacketTunnelProvider/ }",
            "let pattern = optionalRegex ?? /extension PacketTunnelProvider/",
            "let pattern = chosen ? /extension PacketTunnelProvider/ : /other/",
            "switch /extension PacketTunnelProvider/ { default: break }",
            "let b = 1 ∼ /extension PacketTunnelProvider/",
            "let b = 1 ∼⃗ /extension PacketTunnelProvider/",
            "let x = 1\n/extension PacketTunnelProvider/.use()",
            "let x = 1 /*\r*/ /extension PacketTunnelProvider/.use()",
            "let x = 1 /* nested /*\n*/ */ /extension PacketTunnelProvider/.use()",
            #"let pattern = /extension PacketTunnelProvider\ /"#,
            "let pattern = /extension PacketTunnelProvider\\\t/",
]

    /// The floors. Raise them when adding coverage; never lower them.
    ///
    /// 🔴 THIS RATCHET EXISTS BECAUSE THE HARNESS HAD AN ASYMMETRIC ORACLE, and that asymmetry —
    /// not carelessness — produced every repeated regression while this scanner was written.
    ///
    /// WIDENING the scanner has a loud automatic detector: the real tree is scanned on every
    /// `swift test` and must stay clean, so an over-reach fails immediately. Three of three
    /// over-reaches were caught that way, by the author, inside the commit that made them.
    ///
    /// NARROWING it had none. A clean tree stays clean whether the scanner sees a construct or not,
    /// so lost coverage is invisible — and four of four coverage losses shipped and were caught only
    /// by external review, one of them a "fix" that ERASED code (`width/2 // note`, where a
    /// comment's slash was read as a regex terminator).
    ///
    /// The corpus is the missing detector: every construct keeps a spelling, and the counts only go
    /// up. Shrinking the evidence now fails a test instead of going quiet.
    static let spellingFloor = 26
    static let lookalikeFloor = 22

    func testTheCorpusOnlyGrowsAndEveryEntryStillDiscriminates() {
        XCTAssertGreaterThanOrEqual(
            Self.spellingCorpus.count, Self.spellingFloor,
            """
            A declaration spelling was removed. The floor only goes up — if the scanner genuinely \
            no longer needs a construct, argue it in the diff rather than shrinking the evidence \
            that it does.
            """
        )
        XCTAssertGreaterThanOrEqual(
            Self.lookalikeCorpus.count, Self.lookalikeFloor,
            "a lookalike was removed; the brake on over-reach is what keeps narrowing fixes honest"
        )
        XCTAssertEqual(Set(Self.spellingCorpus).count, Self.spellingCorpus.count,
                       "duplicate spellings inflate the count without adding coverage")
        XCTAssertEqual(Set(Self.lookalikeCorpus).count, Self.lookalikeCorpus.count,
                       "duplicate lookalikes inflate the count without adding coverage")
    }

    // MARK: - Declarations that DO extend the class

    func testEveryLegalSpellingOfTheDeclarationIsFound() {
        for spelling in Self.spellingCorpus {
            XCTAssertEqual(
                extensionNameExtending(names, in: spelling), "PacketTunnelProvider",
                "this declaration extends the class but the scan missed it: \(spelling)"
            )
        }
    }

    // MARK: - Text that does NOT extend the class

    func testQuotedAndNamedLookalikesAreNotReported() {
        for text in Self.lookalikeCorpus {
            XCTAssertNil(
                extensionNameExtending(names, in: text),
                "this does not extend the class but the scan reported it: \(text)"
            )
        }
    }

    // MARK: - The scanner itself

    func testCommentsAndStringsAreBlankedWithoutMovingAnythingElse() {
        let source = """
        let a = 1 // trailing
        /* block
           spanning */
        let b = "text"
        let c = 2
        """
        let code = sourceOutsideCommentsAndStrings(source)
        XCTAssertEqual(
            code.count, source.count,
            "offsets must survive blanking, or every reported location shifts"
        )
        XCTAssertEqual(
            code.filter { $0 == "\n" }.count, source.filter { $0 == "\n" }.count,
            "line numbers must survive blanking"
        )
        XCTAssertTrue(code.contains("let a = 1"))
        XCTAssertTrue(code.contains("let c = 2"))
        XCTAssertFalse(code.contains("trailing"))
        XCTAssertFalse(code.contains("spanning"))
        XCTAssertFalse(code.contains("text"))
    }

    func testANestedBlockCommentEndsWhereSwiftSaysItDoes() {
        // A non-nesting scanner stops at the first `*/` and treats the rest as code — which is how
        // `extension /* /* */ */ X` slipped past the matcher (Kilo, PR #651).
        let code = sourceOutsideCommentsAndStrings("/* /* inner */ still comment */ let after = 1")
        XCTAssertFalse(code.contains("inner"))
        XCTAssertFalse(code.contains("still comment"))
        XCTAssertTrue(code.contains("let after = 1"))
    }

    func testAnEscapedQuoteDoesNotEndAStringEarly() {
        // 🔴 The input matters more than the assertion. The first version of this test used
        // `"he said \"hi\""`, whose quotes re-pair by accident: a scanner that ignores escapes ends
        // the literal early, then treats `hi` as code and opens a NEW literal that closes on the
        // next quote, and the tail survives either way. Disabling escape handling did not fail it.
        //
        // An ODD number of quotes after the escape is what separates the two: ignoring the escape
        // leaves a literal open to end of file, which blanks the code that follows.
        let code = sourceOutsideCommentsAndStrings(#"let a = "she said \"" ; let secret = 1"#)
        XCTAssertFalse(code.contains("she said"), "the literal's contents must be blanked")
        XCTAssertTrue(
            code.contains("let secret = 1"),
            "the escaped quote did not end the literal, so the code after it was swallowed"
        )
    }

    func testARawStringEndsOnlyAtItsOwnHashDepth() {
        // `"#` inside a `##"…"##` literal is content, not a terminator.
        let code = sourceOutsideCommentsAndStrings(
            ###"let a = ##"contains "# inside"## ; let b = 2"###)
        XCTAssertFalse(code.contains("contains"))
        XCTAssertFalse(code.contains("inside"))
        XCTAssertTrue(code.contains("let b = 2"))
    }

    func testInterpolationIsCodeAndItsNestedLiteralsAreNot() {
        // `"mode: \(chosen ? "yes" : "no")"` — a scanner with no notion of interpolation ends the
        // literal at the quote before `yes`, after which the literal's contents read as code and
        // the code after it reads as a string (Kilo, PR #651).
        let code = sourceOutsideCommentsAndStrings(
            #"let a = "mode: \(chosen ? "yes" : "no")" ; let secret = 1"#)
        XCTAssertFalse(code.contains("mode"), "the literal's own text must be blanked")
        XCTAssertFalse(code.contains("yes"), "a literal nested inside an interpolation is still a literal")
        XCTAssertTrue(
            code.contains("chosen ?"),
            "an interpolated expression EXECUTES, so it must survive as code — a mutating call in one is a real write"
        )
        XCTAssertTrue(
            code.contains("let secret = 1"),
            "the literal ended at the wrong quote, so real code after it was swallowed"
        )
    }

    func testAParenthesisInsideAnInterpolatedLiteralDoesNotEndTheInterpolation() {
        // `"value: \(")")"` — counting parens without tracking the nested literal ends the
        // interpolation on the `)` that is string CONTENT (Codex, PR #651).
        let code = sourceOutsideCommentsAndStrings(#"let a = "value: \(")")" ; let secret = 1"#)
        XCTAssertTrue(
            code.contains("let secret = 1"),
            "the interpolation ended on a parenthesis that was literal content"
        )
    }

    func testInterpolationNestsToArbitraryDepth() {
        let code = sourceOutsideCommentsAndStrings(
            #"let a = "\(outer("\(inner("x"))"))" ; let secret = 1"#)
        XCTAssertTrue(code.contains("outer("), "the outer interpolated call is code")
        XCTAssertTrue(code.contains("inner("), "so is the one nested inside a nested literal")
        XCTAssertFalse(code.contains(#""x""#), "the innermost literal's text is still blanked")
        XCTAssertTrue(code.contains("let secret = 1"))
    }

    func testAParenthesisedCallInsideAnInterpolationDoesNotEndItEarly() {
        // 🔴 This case exists because the arbitrary-depth test above does NOT catch it: there the
        // mistracked parens happen to re-balance, so the scanner recovers by coincidence and the
        // assertions still hold. Here they do not. Untracked parens close the interpolation on the
        // `)` of `f(1)`, after which the literal's remaining TEXT reads as code and the code after
        // the literal reads as a string.
        let code = sourceOutsideCommentsAndStrings(#"let a = "head\(f(1))tail" ; let secret = 1"#)
        XCTAssertTrue(code.contains("f(1)"), "the interpolated call is code")
        XCTAssertFalse(code.contains("tail"), "text after the interpolation is still literal text")
        XCTAssertTrue(
            code.contains("let secret = 1"),
            "the interpolation closed early, so the literal ran on and swallowed real code"
        )
    }

    func testARawStringEscapeNeedsTheLiteralsOwnHashDepth() {
        // At `##"…"##` the escape is `\##`; a lone `\#` is ordinary content. Treating it as an
        // escape blanks two bytes too few and desynchronises everything after (Codex, PR #651).
        let code = sourceOutsideCommentsAndStrings(###"let a = ##"\#"## ; let secret = 1"###)
        XCTAssertTrue(
            code.contains("let secret = 1"),
            "a lone \\# was treated as an escape, so the literal ran past its terminator"
        )
    }

    func testDivisionIsNotMistakenForARegexLiteral() {
        // 🔴 TWO slashes on the line, deliberately. With only one there is nothing to close a
        // regex candidate, so the line survives whatever the rule is and the test proves nothing —
        // it passed with the no-space rule removed. `a / b / c` is the case that discriminates:
        // without the rule, `/ b /` is blanked as a literal.
        let code = sourceOutsideCommentsAndStrings(
            "let ratio = a / b / c\nextension PacketTunnelProvider {}")
        XCTAssertTrue(code.contains("a / b / c"), "division must survive intact")
        XCTAssertEqual(
            extensionNameExtending(names, in: code), "PacketTunnelProvider",
            "a declaration after a division must still be found"
        )
    }

    func testATrailingCommentAfterADivisionIsNotARegexTerminator() {
        // `width/2 // half` — the candidate opens at `/2` and the first `/` after it belongs to the
        // COMMENT. Closing there erased `2 /` and left the comment text standing as code, which is
        // corruption rather than a miss (Kilo, PR #651).
        let code = sourceOutsideCommentsAndStrings(
            "let half = width/2 // half of the width\nlet after = 1")
        XCTAssertTrue(code.contains("width/2"), "the division must survive intact")
        XCTAssertFalse(code.contains("half of the width"), "the comment must still be blanked")
        XCTAssertTrue(code.contains("let after = 1"))
    }

    func testARealRegexLiteralWhoseTerminatorAbutsACommentIsStillBlanked() {
        // The mirror of the case above, and the direction my first guard broke: `/abc/// note` is
        // a literal `/abc/` followed by a comment. Bailing whenever the scanned `/` was followed by
        // `/` discarded the literal and leaked its payload as code (Kilo, PR #651).
        let code = sourceOutsideCommentsAndStrings(
            "let p = /extension PacketTunnelProvider/// a note\nlet after = 1")
        XCTAssertNil(
            extensionNameExtending(names, in: code),
            "the literal was discarded, so its payload read as a declaration"
        )
        XCTAssertTrue(code.contains("let after = 1"))
    }

    func testAMultiLineGenericAliasBinds() {
        let files = ["typealias Hidden<\n    T\n> = PacketTunnelProvider", "extension Hidden<Int> {}"]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertTrue(resolved.contains("Hidden"), "a generic clause may span lines")
        XCTAssertEqual(extensionNameExtending(resolved, in: files[1]), "Hidden")
    }

    func testNestedGenericAndSymbolAliasesResolveThroughQualifiedTrivia() {
        let files = [
            "typealias Hidden<T: Foo<Bar<Baz>>> = LavaSecTunnel /* note */ . PacketTunnelProvider",
            "typealias 🐶 = Hidden<Int>",
            "extension 🐶 {}",
        ]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertTrue(resolved.contains("Hidden"))
        XCTAssertTrue(resolved.contains("🐶"))
        XCTAssertEqual(extensionNameExtending(resolved, in: files[2]), "🐶")
    }

    func testAMultiLineExtendedRegexLiteralIsBlanked() {
        // 🔴 The single-line `#/…/#` cases do NOT justify the extended-literal branch: the bare
        // `/…/` rule already blanks their payload, so removing the branch changed nothing. An
        // extended literal may span LINES, which the bare rule cannot follow — that is what the
        // branch is for, and this is the case that proves it.
        let code = sourceOutsideCommentsAndStrings("""
        let pattern = #/
            extension PacketTunnelProvider
        /#
        let after = 1
        """)
        XCTAssertNil(
            extensionNameExtending(names, in: code),
            "a declaration inside a multi-line regex literal is not a declaration"
        )
        XCTAssertTrue(code.contains("let after = 1"), "code after the literal must survive")
    }

    // MARK: - Alias resolution

    func testAliasesResolveAcrossFilesAndHops() {
        // Module scope: the binding and the extension may be in different files, and a chain may
        // pass through several (Codex, PR #651).
        let files = [
            "typealias Hidden = PacketTunnelProvider",
            "typealias Deeper = Hidden",
            "extension Deeper: Equatable {}",
        ]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertTrue(resolved.contains("Deeper"), "an alias chain across files must resolve")
        XCTAssertEqual(extensionNameExtending(resolved, in: files[2]), "Deeper")
    }

    func testUnspacedAndUnicodeAliasesAreCaptured() {
        let files = ["typealias VM=PacketTunnelProvider", "typealias Übergang = PacketTunnelProvider"]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertTrue(resolved.contains("VM"), "`typealias VM=X` binds the name with no spaces")
        XCTAssertTrue(
            resolved.contains("Übergang"),
            "Swift identifiers are Unicode; an ASCII-only class silently drops this binding"
        )
    }

    func testAModuleQualifiedAliasResolvesButANestedOneDoesNot() {
        // Told apart by which half is known: a qualifier that is itself a known name means the tail
        // is nested inside it; anything else in that position is a module (Codex, PR #651).
        let qualified = classNamesExtending(
            "PacketTunnelProvider",
            inAnyOf: ["typealias Hidden = LavaSecTunnel.PacketTunnelProvider"])
        XCTAssertTrue(qualified.contains("Hidden"), "a module-qualified alias is still the class")

        let nested = classNamesExtending(
            "PacketTunnelProvider",
            inAnyOf: ["typealias Inner = PacketTunnelProvider.Something"])
        XCTAssertFalse(nested.contains("Inner"), "a nested type is not the class")
    }

    func testEscapedIdentifiersAndConditionalBranchesInAliases() {
        // Backticks are an identifier escape on `typealias` as much as on `extension`.
        let escaped = classNamesExtending(
            "PacketTunnelProvider",
            inAnyOf: ["typealias `Hidden` = `PacketTunnelProvider`"])
        XCTAssertTrue(escaped.contains("Hidden"), "an escaped alias name and target still bind")

        // Conditional compilation gives one module-scoped name different targets per branch, and
        // `#if` is not evaluated here, so EVERY target must be kept — a dictionary would drop the
        // class-bound branch if the other came last (Codex, PR #651). Ordered both ways so the
        // test cannot pass by luck of iteration.
        for branches in [
            "#if DEBUG\ntypealias Hidden = PacketTunnelProvider\n#else\ntypealias Hidden = Unrelated\n#endif",
            "#if DEBUG\ntypealias Hidden = Unrelated\n#else\ntypealias Hidden = PacketTunnelProvider\n#endif",
        ] {
            XCTAssertTrue(
                classNamesExtending("PacketTunnelProvider", inAnyOf: [branches]).contains("Hidden"),
                "a conditional branch binding the class must not be dropped by the other branch"
            )
        }
    }

    func testAnExtendedRegexLiteralHonoursEscapedDelimiters() {
        // `\/#` is regex content, not the terminator, so the literal runs past it.
        let code = sourceOutsideCommentsAndStrings(
            ##"let p = #/text \/# extension PacketTunnelProvider /# ; let after = 1"##)
        XCTAssertNil(
            extensionNameExtending(names, in: code),
            "an escaped delimiter ended the literal early, exposing its payload as code"
        )
        XCTAssertTrue(code.contains("let after = 1"), "code after the literal must survive")
    }

    func testAQualifiedExtensionResolvesThroughANamespacedAlias() {
        // `enum Namespace { typealias Hidden = PacketTunnelProvider }` then
        // `extension Namespace.Hidden` extends the CLASS (Codex, PR #651). The name must be the
        // last component, which is what keeps `extension PacketTunnelProvider.Nested` excluded.
        let files = ["enum Namespace { typealias Hidden = PacketTunnelProvider }",
                     "extension Namespace.Hidden: Equatable {}"]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertEqual(extensionNameExtending(resolved, in: files[1]), "Hidden")
        XCTAssertNil(
            extensionNameExtending(resolved, in: "extension PacketTunnelProvider.Nested {}"),
            "a nested type must still be excluded"
        )
    }

    func testProtectedAliasesMustHaveUnambiguousNamesAcrossScopes() {
        // This architecture check intentionally rejects an ambiguous leaf name. It has no Swift
        // type-resolution context; the remedy is an unambiguous alias or the concrete class name,
        // not a new scope/type checker in the test harness (PR #659).
        let sources = [
            "struct Namespace { typealias Hidden = PacketTunnelProvider }; struct Hidden {}",
            "extension Hidden {}",
        ]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: sources)
        XCTAssertEqual(extensionNameExtending(resolved, in: sources[1]), "Hidden")
        XCTAssertEqual(extensionNameExtending(resolved, in: "extension Namespace.Hidden {}"), "Hidden")
    }

    func testAGenericAliasBindsAndItsExtensionIsFound() {
        let files = ["typealias Hidden<T> = PacketTunnelProvider", "extension Hidden<Int> {}"]
        let resolved = classNamesExtending("PacketTunnelProvider", inAnyOf: files)
        XCTAssertTrue(resolved.contains("Hidden"), "a generic parameter list does not change the target")
        XCTAssertEqual(extensionNameExtending(resolved, in: files[1]), "Hidden")
    }

    func testAParenthesisedAliasTargetStillBinds() {
        let resolved = classNamesExtending(
            "PacketTunnelProvider", inAnyOf: ["typealias Hidden = (PacketTunnelProvider)"])
        XCTAssertTrue(resolved.contains("Hidden"), "parentheses around a target do not change it")
    }

    func testAnAliasToANestedTypeIsNotTheClass() {
        let resolved = classNamesExtending(
            "PacketTunnelProvider", inAnyOf: ["typealias Inner = PacketTunnelProvider.Something"])
        XCTAssertFalse(
            resolved.contains("Inner"),
            "extending a nested type adds no members to the class, so this must not be flagged"
        )
    }

    func testAQuotedAliasIsNotABinding() {
        let resolved = classNamesExtending(
            "PacketTunnelProvider",
            inAnyOf: [#"// typealias Hidden = PacketTunnelProvider is not declared here"#])
        XCTAssertFalse(resolved.contains("Hidden"), "a binding named in a comment is not a binding")
    }
}
