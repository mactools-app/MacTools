import Foundation
import XCTest
@testable import AIUsagePlugin

/// The AI page's main flow: agent log lines become turns and usage records, and usage becomes
/// API value through the price list. A wrong turn or count shows on the page; a wrong price
/// family puts another model's price on it.
final class AIUsageLogAndPricingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        AgentPricing.install(.empty)
        super.tearDown()
    }

    // MARK: Claude Code logs

    func testClaudePromptAndReplyMakeOneTurnWithItsUsage() throws {
        var state = AgentLogState()
        let prompt = #"{"type":"user","sessionId":"s1","cwd":"/Users/me/Projects/Island/","timestamp":"2026-11-17T01:00:00.000Z","message":{"role":"user","content":"Fix the card"}}"#
        XCTAssertEqual(parse(prompt, &state), [.turnBegan(try date("2026-11-17T01:00:00.000Z"))])
        XCTAssertTrue(state.turnOpen)
        XCTAssertEqual(state.project, "Island")
        XCTAssertEqual(state.session, "s1")

        let reply = #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-11-17T01:00:05.000Z","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":40}}}"#
        let entries = parse(reply, &state)
        XCTAssertEqual(entries.count, 2)
        guard case let .usage(key, record, _) = entries.first else { return XCTFail("no usage: \(entries)") }
        XCTAssertEqual(key, "claude:m1:r1", "the key deduplicates a response written twice")
        XCTAssertEqual(record.provider, .claude)
        XCTAssertEqual(record.model, "claude-opus-5-5")
        XCTAssertEqual(record.project, "Island")
        XCTAssertEqual(record.tokens, AgentTokens(input: 10, cacheWrite: 200, cacheRead: 3000, output: 40))
        XCTAssertEqual(entries.last, .turnEnded(try date("2026-11-17T01:00:05.000Z"), completed: true, duration: nil))
        XCTAssertFalse(state.turnOpen)
    }

    func testInterruptionEndsTheTurnUnfinishedAndSubagentsNeverOpenOne() {
        var state = AgentLogState()
        _ = parse(#"{"type":"user","sessionId":"s1","message":{"role":"user","content":"Go"}}"#, &state)
        let interrupted = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertEqual(parse(interrupted, &state), [.turnEnded(nil, completed: false, duration: nil)])
        XCTAssertFalse(state.turnOpen)

        let subagent = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"Search the code"}}"#
        XCTAssertEqual(parse(subagent, &state), [])
        XCTAssertFalse(state.turnOpen)
    }

    // MARK: Codex logs

    func testCodexInputCountsSplitCachedTokensOutAndNeverGoNegative() {
        XCTAssertEqual(AgentLogParser.codexTokens(["input_tokens": 1_000, "cached_input_tokens": 800,
                                                   "output_tokens": 50, "reasoning_output_tokens": 20]),
                       AgentTokens(input: 200, cacheWrite: 0, cacheRead: 800, output: 50, reasoning: 20))
        // A damaged line reporting more cached than total input.
        XCTAssertEqual(AgentLogParser.codexTokens(["input_tokens": 1_000, "cached_input_tokens": 1_500]),
                       AgentTokens(input: 0, cacheWrite: 0, cacheRead: 1_000, output: 0))
    }

    // MARK: Prices

    func testShippedPriceListDecodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../Resources/agent-prices.json").standardizedFileURL
        let list = try XCTUnwrap(AgentPriceList.decode(try Data(contentsOf: url)), "the app would show no prices")
        XCTAssertFalse(list.claude.isEmpty)
        XCTAssertFalse(list.codex.isEmpty)
    }

    func testModelsTakeOnlyTheirOwnFamilysPrice() {
        let list = Self.list
        XCTAssertEqual(AgentPricing.price(for: "claude-opus-5", in: list), Self.opus)
        // A snapshot date and a provider's prefix and tag are the same model.
        XCTAssertEqual(AgentPricing.price(for: "anthropic/claude-opus-5-20261101@v1", in: list), Self.opus)
        // Another version, or a smaller sibling, must not borrow the price.
        XCTAssertNil(AgentPricing.price(for: "claude-opus-5-6", in: list))
        XCTAssertNil(AgentPricing.price(for: "gpt-6.1", in: list))
        XCTAssertNil(AgentPricing.price(for: "gpt-6-mini", in: list))
        XCTAssertEqual(AgentPricing.price(for: "gpt-6-2026-10-01", in: list), Self.gpt)
    }

    func testCostIsTheAPIValueAndCacheReadsSave() throws {
        AgentPricing.install(Self.list)
        var billable = AgentBillable()
        billable.tokens = AgentTokens(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let priced = AgentPricing.cost(billable, model: "claude-opus-5")
        XCTAssertEqual(try XCTUnwrap(priced.cost), 15 + 1.5 + 75, accuracy: 0.000_1)
        XCTAssertEqual(priced.savings, 15 - 1.5, accuracy: 0.000_1)

        billable.fast = true
        XCTAssertEqual(try XCTUnwrap(AgentPricing.cost(billable, model: "claude-opus-5").cost), (15 + 1.5 + 75) * 2,
                       accuracy: 0.000_1)
        // An unknown model has no figure rather than a wrong one.
        XCTAssertNil(AgentPricing.cost(billable, model: "claude-unknown-9").cost)
    }

    // MARK: Helpers

    private static let opus = AgentPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75, cacheWriteLong: 30,
                                         fastMultiplier: 2)
    private static let gpt = AgentPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25, cacheWriteLong: 1.25)
    private static let list = AgentPriceList(updated: Date(timeIntervalSince1970: 1_790_000_000),
                                             claude: [.init(id: "claude-opus-5", price: opus)],
                                             codex: [.init(id: "gpt-6", price: gpt)],
                                             claudePlans: [], codexPlans: [], webSearch: 0.01, usOnlyMultiplier: 1.1)

    private func parse(_ line: String, _ state: inout AgentLogState) -> [AgentLogEntry] {
        AgentLogParser.parseClaude(Data(line.utf8), state: &state, now: now)
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(AgentTimestamp.parse(text))
    }
}
