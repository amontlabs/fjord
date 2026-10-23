import Foundation
import Testing
@testable import Fjord

@MainActor
@Suite(.serialized) struct PaletteMatchTests {
    private func item(_ id: String, _ title: String, keywords: [String] = [], weight: Double = 1, date: Date? = nil)
        -> PaletteItem {
        PaletteItem(id: id, kind: .page, title: title, keywords: keywords, icon: .symbol("circle"), date: date, weight: weight,
                    actions: [PaletteAction(id: "open", title: "Open", run: {})])
    }

    private func ranked(_ query: String, _ items: [PaletteItem], usage: PaletteUsage? = nil, now: Date = Date(), limit: Int = 50)
        -> [PaletteHit] {
        PaletteRanker.rank(query, in: PaletteIndex(items), usage: usage, now: now, limit: limit)
    }

    private func ids(_ query: String, _ items: [PaletteItem], usage: PaletteUsage? = nil, now: Date = Date()) -> [String] {
        ranked(query, items, usage: usage, now: now).map(\.id)
    }

    /// The pieces of the title the hit highlights.
    private func lit(_ hit: PaletteHit) -> [String] { hit.ranges.map { String(hit.item.title[$0]) } }

    // MARK: Folding

    @Test func foldingDropsAccentsAndCase() {
        #expect(PaletteText.fold("Café") == "cafe")
        #expect(PaletteText.fold("Façade") == "facade")
        #expect(PaletteText.fold("Señor ÉCOLE") == "senor ecole")
        // A decomposed accent folds the same as a precomposed one.
        #expect(PaletteText.fold("Cafe\u{301}") == "cafe")
    }

    @Test func foldingSpellsOutLigaturesAndEszett() {
        #expect(PaletteText.fold("Œuvre") == "oeuvre")
        #expect(PaletteText.fold("cœur") == "coeur")
        #expect(PaletteText.fold("Æon") == "aeon")
        #expect(PaletteText.fold("Straße") == "strasse")
    }

    @Test func foldingStraightensQuotesAndSpaces() {
        #expect(PaletteText.fold("Don’t “quote”") == "don't \"quote\"")
        #expect(PaletteText.fold("a\u{00A0}b") == "a b")
    }

    @Test func accentedAndPlainSpellingsFindEachOther() {
        #expect(ids("oeuvre", [item("a", "Œuvre")]) == ["a"])
        #expect(ids("œuvre", [item("a", "Oeuvre")]) == ["a"])
        #expect(ids("coeur", [item("a", "Mon cœur")]) == ["a"])
        #expect(ids("cafe", [item("a", "Café")]) == ["a"])
        #expect(ids("café", [item("a", "Cafe")]) == ["a"])
        #expect(ids("don't", [item("a", "Don’t stop")]) == ["a"])
        #expect(ids("strasse", [item("a", "Straße")]) == ["a"])
    }

    @Test func emptyAndBlankQueriesMatchNothing() {
        #expect(ids("", [item("a", "Router")]).isEmpty)
        #expect(ids("   ", [item("a", "Router")]).isEmpty)
    }

    // MARK: Tiers

    @Test func eachTierBeatsTheNextOne() {
        let items = [
            item("keyword", "Zebra", keywords: ["art"]),
            item("fuzzy", "Barrister"),
            item("substring", "Smart tab"),
            item("acronym", "Router tools"),
            item("wordprefix", "Open rtfm"),
            item("prefix", "Rtl support"),
            item("exact", "RT"),
        ]
        #expect(ids("rt", items) == ["exact", "prefix", "wordprefix", "acronym", "substring", "fuzzy", "keyword"])
    }

    @Test func aPrefixBeatsABetterFuzzyMatch() {
        let items = [item("fuzzy", "Xaxbxc"), item("prefix", "Abc and a long title that goes on")]
        #expect(ids("abc", items) == ["prefix", "fuzzy"])
    }

    @Test func aKeywordMatchIsBelowAnyTitleMatch() {
        let items = [item("keyword", "Fix crash", keywords: ["#482", "owner/repo#482"]), item("fuzzy", "Quartz one deux")]
        #expect(ids("#482", items) == ["keyword"])
        #expect(ids("qod", items) == ["fuzzy"])
        let both = [item("keyword", "Fix crash", keywords: ["router"]), item("fuzzy", "Rotate output utility, then retry")]
        #expect(ids("router", both) == ["fuzzy", "keyword"])
    }

    @Test func keywordsMatchIssueNumbersReposAndUrls() {
        let pr = item("pr", "Fix crash", keywords: ["#482", "owner/repo#482", "https://github.com/owner/repo/pull/482"])
        let other = item("other", "Add tests", keywords: ["#4821"])
        #expect(ids("#482", [other, pr]) == ["pr", "other"])
        #expect(ids("owner/repo#482", [other, pr]) == ["pr"])
        #expect(ids("https://github.com/owner/repo/pull/482", [other, pr]) == ["pr"])
        #expect(ids("repo#48", [other, pr]) == ["pr"])
    }

    @Test func aSingleLetterOnlyMatchesKeywordsAtAWordStart() {
        #expect(ids("x", [item("a", "Router", keywords: ["alexander"])]).isEmpty)
        #expect(ids("a", [item("a", "Router", keywords: ["alexander"])]) == ["a"])
    }

    @Test func acronymsTakeInitialsAndCamelCase() {
        // Each acronym is ranked against a title that only holds the letters inside a word: the acronym must win by tier.
        let cases: [(query: String, acronym: String, rival: String)] = [
            ("gubi", "getUserById", "Xgubi thing"),
            ("gubi", "get_user_by_id", "Xgubi thing"),
            ("rt", "Router tools", "Smart tab"),
            ("hs", "HTTPServer", "Xhsx"),
            ("m3", "mp3 Player 3", "Xm3x"),
        ]
        for c in cases {
            let items = [item("rival", c.rival), item("acronym", c.acronym)]
            #expect(ids(c.query, items) == ["acronym", "rival"], "\(c.query) -> \(c.acronym)")
            #expect(ids(c.query, items.reversed()) == ["acronym", "rival"], "\(c.query) -> \(c.acronym), reversed")
        }
        #expect(hit("gubi", "getUserById") == ["g", "U", "B", "I"])
    }

    private func hit(_ query: String, _ title: String) -> [String] {
        ranked(query, [item("a", title)]).first.map(lit) ?? []
    }

    @Test func fuzzyPrefersWordStartsRunsAndEarlyLetters() {
        let items = [item("spread", "Xaxxxbxxxc"), item("starts", "Xa big charm"), item("run", "Xxabcx")]
        // Consecutive letters first (a substring), then the one with the word starts, then the spread one.
        #expect(ids("abc", items) == ["run", "starts", "spread"])
        #expect(ids("axbc", [item("late", "Zzzzzzzzzzzzzzz axbc"), item("gaps", "Aaxbxc")]).first == "late")
    }

    @Test func fuzzyDoesNotTolerateTypos() {
        #expect(ids("rotuer", [item("a", "Router")]).isEmpty)
        #expect(ids("routerr", [item("a", "Router")]).isEmpty)
    }

    @Test func multiWordQueriesMatchInAnyOrder() {
        let items = [item("a", "Router tools"), item("b", "Tools for the Router"), item("c", "Router"), item("d", "Settings")]
        #expect(Set(ids("tools router", items)) == ["a", "b"])
        #expect(Set(ids("ro to", items)) == ["a", "b"])
        #expect(ids("router zzz", items).isEmpty)
    }

    @Test func aMultiWordQueryIsAsGoodAsItsWorstWord() {
        let items = [
            item("both", "Fix router crash"),
            item("keyword", "Fix crash", keywords: ["router"]),
            item("phrase", "Router tools"),
        ]
        #expect(ids("router tools", items) == ["phrase"])
        #expect(ids("fix router", items) == ["both", "keyword"])
        // The whole phrase as the start of the title is a prefix, above words found apart.
        let apart = [item("apart", "The tools of the router"), item("start", "Router tools of the trade")]
        #expect(ids("router tools", apart) == ["start", "apart"])
    }

    @Test func aWordFoundInTheTitleAndAnotherInAKeywordMatches() {
        let items = [item("a", "Fix crash", keywords: ["#482"])]
        #expect(ids("crash #482", items) == ["a"])
        #expect(lit(ranked("crash #482", items)[0]) == ["crash"])
    }

    @Test func limitCapsTheOutputWithTheBestOnes() {
        let items = (0..<30).map { item("i\($0)", "Item \($0) router") } + [item("best", "Router")]
        let hits = ranked("router", items, limit: 5)
        #expect(hits.count == 5)
        #expect(hits[0].id == "best")
    }

    // MARK: Highlights

    @Test func highlightsAreRangesOfTheOriginalTitle() {
        #expect(hit("rou", "Router tools") == ["Rou"])
        #expect(hit("tools", "Router tools") == ["tools"])
        #expect(hit("to ro", "Router tools") == ["Ro", "to"])
        #expect(hit("router tools", "Router tools") == ["Router tools"])
        #expect(hit("cafe", "Café du coin") == ["Café"])
        #expect(hit("du", "Café du coin") == ["du"])
        #expect(hit("coin", "Café du coin") == ["coin"])
    }

    @Test func highlightsFollowTheLigaturesOfTheOriginal() {
        #expect(hit("oeuvre", "Une Œuvre rare") == ["Œuvre"])
        // Half of a spelled-out letter lights the whole letter.
        #expect(hit("o", "Œuvre") == ["Œ"])
        #expect(hit("coeur", "Mon cœur") == ["cœur"])
        #expect(hit("strasse", "Die Straße") == ["Straße"])
        #expect(hit("e", "Æon e") == ["e"])
    }

    @Test func highlightsKeepAnAccentWithItsLetter() {
        #expect(hit("cafe", "Cafe\u{301} noir") == ["Cafe\u{301}"])
        #expect(hit("ecole", "L’École") == ["École"])
    }

    @Test func highlightsOfFuzzyMatchesAreTheLetters() {
        #expect(hit("rtl", "Router tools list") == ["R", "t", "l"])
        let lit = hit("abc", "Xaxbxc")
        #expect(lit == ["a", "b", "c"])
    }

    // MARK: Weight and usage

    @Test func weightReordersOnlyInsideATier() {
        let items = [item("plain", "Rolex"), item("heavy", "Rome and more", weight: 3), item("light", "Rodeo", weight: 0.2)]
        // All prefixes: weight over the match score.
        #expect(ids("ro", items) == ["heavy", "plain", "light"])
        // A heavy fuzzy match stays below a plain prefix.
        let tiers = [item("prefix", "Router and a quite long title indeed"), item("heavy", "Xrxoxc", weight: 50)]
        #expect(ids("ro", tiers) == ["prefix", "heavy"])
    }

    @Test func usageReordersOnlyInsideATier() {
        let usage = PaletteUsage(defaults: nil)
        let now = Date()
        let items = [item("prefix", "Router and a quite long title indeed"), item("fuzzy", "Xrxoxc")]
        for _ in 0..<20 { usage.record("fuzzy", query: "ro", now: now) }
        #expect(ids("ro", items, usage: usage, now: now) == ["prefix", "fuzzy"])
        // Inside a tier, picks decide.
        let equals = [item("a", "Rolx"), item("b", "Rome")]
        #expect(ids("ro", equals, usage: usage, now: now) == ["a", "b"])
        usage.record("b", query: "ro", now: now)
        #expect(ids("ro", equals, usage: usage, now: now) == ["b", "a"])
    }

    @Test func frecencyDecaysWithAHalfLifeOfAWeek() {
        let usage = PaletteUsage(defaults: nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        usage.record("a", query: "", now: t)
        let fresh = usage.boost(for: "a", query: "", now: t)
        let week = usage.boost(for: "a", query: "", now: t.addingTimeInterval(7 * 86400))
        let year = usage.boost(for: "a", query: "", now: t.addingTimeInterval(365 * 86400))
        #expect(fresh > week)
        #expect(week > year)
        #expect(year >= 1)
        #expect(abs(fresh - (1 + 0.3 * log2(2))) < 0.01)
        #expect(abs(week - (1 + 0.3 * log2(1.5))) < 0.01)
        #expect(usage.boost(for: "never", query: "", now: t) == 1)
        // Two picks are worth more than one.
        usage.record("a", query: "", now: t)
        #expect(usage.boost(for: "a", query: "", now: t) > fresh)
    }

    @Test func aPickLearnsItsQueryAndTheOnesThatExtendIt() {
        let usage = PaletteUsage(defaults: nil)
        let now = Date()
        // "Roux" is the better match for "rou" and "ro"; "Router" is what gets picked.
        let items = [item("roux", "Roux"), item("router", "Router tools")]
        #expect(ids("ro", items, usage: usage, now: now) == ["roux", "router"])
        #expect(ids("rou", items, usage: usage, now: now) == ["roux", "router"])
        usage.record("router", query: "ro", now: now)
        usage.record("router", query: "ro", now: now)
        #expect(ids("ro", items, usage: usage, now: now) == ["router", "roux"])
        #expect(ids("rou", items, usage: usage, now: now) == ["router", "roux"])
        // The learning is the query's: another query does not get it (only the item's own frecency applies).
        let learned = usage.boost(for: "router", query: "ro", now: now)
        let unrelated = usage.boost(for: "router", query: "xy", now: now)
        #expect(learned > unrelated)
        #expect(unrelated > 1)
        // A query the learned one extends borrows less, an unrelated one nothing.
        let shorter = usage.boost(for: "router", query: "r", now: now)
        #expect(shorter > unrelated)
        #expect(shorter < learned)
    }

    @Test func learnedQueriesFadeOverDays() {
        let usage = PaletteUsage(defaults: nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        usage.record("router", query: "ro", now: t)
        let soon = usage.boost(for: "router", query: "ro", now: t)
        let later = usage.boost(for: "router", query: "ro", now: t.addingTimeInterval(60 * 86400))
        #expect(later < soon)
        #expect(later >= 1)
    }

    @Test func recentListsTheLastPicksNewestFirst() {
        let usage = PaletteUsage(defaults: nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        usage.record("a", query: "", now: t)
        usage.record("b", query: "x", now: t.addingTimeInterval(10))
        usage.record("c", query: "", now: t.addingTimeInterval(20))
        #expect(usage.recent(2) == ["c", "b"])
        #expect(usage.recent(10) == ["c", "b", "a"])
        usage.record("a", query: "", now: t.addingTimeInterval(30))
        #expect(usage.recent(3) == ["a", "c", "b"])
        // At the same instant, the later pick is the newer.
        usage.record("d", query: "", now: t.addingTimeInterval(30))
        #expect(usage.recent(2) == ["d", "a"])
        #expect(usage.recent(0).isEmpty)
    }

    @Test func usageSurvivesAReload() throws {
        let name = "palette-usage-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let first = PaletteUsage(defaults: defaults)
        first.record("router", query: "ro", now: t)
        first.record("router", query: "ro", now: t.addingTimeInterval(5))
        first.record("settings", query: "", now: t.addingTimeInterval(9))
        let data = try #require(defaults.data(forKey: "palette.usage"))
        #expect(data.count < 400)
        let second = PaletteUsage(defaults: defaults)
        let at = t.addingTimeInterval(86400)
        #expect(second.recent(5) == ["settings", "router"])
        #expect(second.boost(for: "router", query: "rou", now: at) == first.boost(for: "router", query: "rou", now: at))
        #expect(second.boost(for: "settings", query: "", now: at) == first.boost(for: "settings", query: "", now: at))
        // The sequence goes on from where it was.
        second.record("a", query: "", now: t.addingTimeInterval(9))
        #expect(second.recent(1) == ["a"])
        // Nothing is stored without defaults.
        let none = PaletteUsage(defaults: nil)
        none.record("x", query: "y")
        #expect(PaletteUsage(defaults: defaults).recent(10).contains("x") == false)
    }

    @Test func usageIsCappedKeepingTheStrongest() {
        let usage = PaletteUsage(defaults: nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<600 { usage.record("item\(n)", query: "q\(n % 7)", now: t.addingTimeInterval(Double(n))) }
        #expect(usage.recent(1000).count == 500)
        #expect(usage.recent(1).first == "item599")
        #expect(usage.recent(1000).contains("item0") == false)
    }

    // MARK: Normalisation and limits

    @Test func composedAndDecomposedSpellingsFoldAlike() {
        #expect(PaletteText.fold("ǽ") == "ae")
        #expect(PaletteText.fold("æ\u{301}") == "ae")
        #expect(PaletteText.fold("Ǿ") == "o")
        #expect(PaletteText.fold("Ø\u{301}") == "o")
        #expect(PaletteText.fold("Œ\u{301}uvre") == PaletteText.fold("Ǽuvre").replacingOccurrences(of: "ae", with: "oe"))
        #expect(PaletteText.fold("Éc") == PaletteText.fold("E\u{301}c"))
    }

    @Test func composedAndDecomposedTitlesRankAlike() {
        // "ec" starts the word École in both spellings (an accented capital after a capital run), a word-start prefix
        // that beats an acronym rival; if the accent hid the boundary it would only be a substring and lose to it.
        let rival = item("rival", "Easy Cat")
        for title in ["HÉcole Router", "HE\u{301}cole Router"] {
            #expect(ids("ec", [rival, item("a", title)]) == ["a", "rival"], "\(title)")
            #expect(ids("ec", [item("a", title), rival]) == ["a", "rival"], "\(title)")
        }
        #expect(hit("ec", "HE\u{301}cole Router") == ["E\u{301}c"])
    }

    @Test func hugeTextsAndQueriesAreScannedInLinearTime() {
        let title = String(repeating: "a", count: 64_000) + "xb"
        let items = [item("t", title, keywords: [title]), item("k", "Other", keywords: [title])]
        for query in [String(repeating: "a", count: 32_000) + "b", String(repeating: "a", count: 200) + "b",
                      String(repeating: "a ", count: 100) + "b"] {
            var hits: [PaletteHit] = []
            // As in `fiveThousandItemsRankQuickly`: CPU time, best of three. Quadratic work would take seconds however it is counted.
            let took = (0..<3).map { _ in threadTime { hits = ranked(query, items) } }.min()!
            #expect(took < .milliseconds(500), "\(query.count) letters took \(took)")
            _ = hits
        }
        // Past the cap the query is cut, so a long paste still finds what starts like it.
        #expect(ids(String(repeating: "a", count: 3000), items).contains("t"))
        // Short queries on repetitive text still find the word and its place.
        #expect(hit("axb", "a" + String(repeating: "a", count: 5000) + "xb") == ["axb"])
    }

    // MARK: Caps

    @Test func oneItemWithManyQueriesStaysWithinTheCap() {
        let usage = PaletteUsage(defaults: nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 0..<2105 {
            usage.record("router", query: String(format: "k%05d", n), now: t.addingTimeInterval(Double(n)))
        }
        #expect(usage.kept.queries == 2000)
        // The oldest are gone (only the item's own frecency is left), the newest is learned.
        let unrelated = usage.boost(for: "router", query: "zzz", now: t.addingTimeInterval(3000))
        #expect(usage.boost(for: "router", query: "k00000", now: t.addingTimeInterval(3000)) == unrelated)
        #expect(usage.boost(for: "router", query: "k02104", now: t.addingTimeInterval(3000)) > unrelated)
    }

    @Test func equalStrengthsAreEvictedOldestFirst() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        // Items: all picked at the same instant, so the first picked goes.
        let items = PaletteUsage(defaults: nil)
        for n in 0..<501 { items.record(String(format: "item%03d", 500 - n), query: "", now: t) }
        #expect(items.kept.items == 500)
        #expect(items.recent(1000).contains("item500") == false)
        #expect(items.recent(1000).contains("item000"))
        // Pairs: the same strength and time, so the smallest id goes (never the one just recorded).
        let pairs = PaletteUsage(defaults: nil)
        for n in 0..<2001 { pairs.record(String(format: "p%04d", 2000 - n), query: "k", now: t) }
        #expect(pairs.kept.queries == 2000)
        #expect(pairs.boost(for: "p0001", query: "k", now: t) == pairs.boost(for: "p0001", query: "zzz", now: t))
        #expect(pairs.boost(for: "p0002", query: "k", now: t) > pairs.boost(for: "p0002", query: "zzz", now: t))
        #expect(pairs.boost(for: "p0000", query: "k", now: t) > pairs.boost(for: "p0000", query: "zzz", now: t))
    }

    // MARK: Ties

    @Test func tiesGoToTheNewerThenTheTitleThenTheId() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            item("c2", "Same", date: t), item("c1", "Same", date: t),
            item("new", "Same", date: t.addingTimeInterval(100)),
            item("none", "Same"),
            item("zed", "Same title z", date: t),
        ]
        let expected = ["new", "c1", "c2", "none"]
        #expect(Array(ids("same", items).prefix(4)) == expected)
        for _ in 0..<3 {
            #expect(ids("same", items.shuffled()).prefix(4).elementsEqual(expected))
        }
        // By title when the dates are the same.
        let titled = [item("1", "Rb"), item("2", "Ra"), item("3", "Rc")].map { $0 }
        #expect(ids("r", titled.shuffled()) == ["2", "1", "3"])
    }

    // MARK: Speed

    @Test func fiveThousandItemsRankQuickly() {
        let words = ["router", "triage", "session", "settings", "inbox", "archive", "computer", "prompt", "category", "token",
                     "github", "review", "deploy", "branch", "commit", "silo", "guest", "console", "project", "notify"]
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var items: [PaletteItem] = []
        for n in 0..<5000 {
            let title = (0..<(2 + next(4))).map { _ in words[next(words.count)] }.joined(separator: " ")
            let keywords = (0..<10).map { _ in "\(words[next(words.count)])/\(words[next(words.count)])#\(next(9000))" }
            items.append(item("item:\(n)", title.capitalized, keywords: keywords, date: Date(timeIntervalSince1970: Double(n))))
        }
        var index = PaletteIndex([])
        let build = threadTime { index = PaletteIndex(items) }
        let usage = PaletteUsage(defaults: nil)
        usage.record("item:3", query: "ro")
        var timings: [String] = []
        for query in ["ro", "git hub", "tri ses", "rts", "#4821", "x"] {
            var hits: [PaletteHit] = []
            // The CPU time the ranking itself used, at its best of three: a loaded or throttled runner that takes the core
            // away mid-ranking doesn't count against it. A slower core still does: about 27 ms here on a performance core
            // takes 100 on an efficiency one, so the limit leaves room for that and still fails a ranking gone quadratic.
            let took = (0..<3).map { _ in threadTime { hits = PaletteRanker.rank(query, in: index, usage: usage) } }.min()!
            timings.append("\(query): \(took) (\(hits.count) hits)")
            #expect(took < .milliseconds(250), "\(query) took \(took)")
        }
        print("palette matcher, 5000 items: index \(build); " + timings.joined(separator: "; "))
        #expect(build < .seconds(2))
    }
}

/// The CPU time this thread spent running `body`, not the time that passed meanwhile.
private func threadTime(_ body: () -> Void) -> Duration {
    func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    let start = now()
    body()
    return .nanoseconds(Int64(now() - start))
}
