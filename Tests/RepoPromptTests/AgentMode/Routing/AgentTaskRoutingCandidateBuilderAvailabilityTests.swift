@testable import RepoPromptApp
import XCTest

/// `hasAvailableTarget` is the Model Router status pill's availability probe. It must answer exactly
/// what a non-empty `build` answers while never constructing candidates.
@MainActor
final class AgentTaskRoutingCandidateBuilderAvailabilityTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    private struct OptionFixture {
        let name: String
        let codex: [AgentModelOption]
        let claude: [AgentModelOption]
    }

    private static func option(_ raw: String) -> AgentModelOption {
        AgentModelOption(rawValue: raw, displayName: raw, description: nil, isDefault: false)
    }

    private static let fullCodex = [
        "gpt-5.6-luna-low", "gpt-5.6-terra-medium", "gpt-5.6-sol-high",
        "gpt-6-luna-low", "gpt-6-sol-medium", "gpt-6-sol-high"
    ].map(option)

    private static let fullClaude = [
        "claude-haiku-4-5", "claude-sonnet-5", "opus", "claude-opus-5-5", "claude-fable-5-1"
    ].map(option)

    private static let optionFixtures: [OptionFixture] = [
        OptionFixture(name: "full", codex: fullCodex, claude: fullClaude),
        OptionFixture(name: "empty", codex: [], claude: []),
        OptionFixture(name: "codex-only", codex: fullCodex, claude: []),
        OptionFixture(name: "claude-only", codex: [], claude: fullClaude),
        OptionFixture(
            name: "unrecognized",
            codex: ["gpt-99-nova-high", "not-a-model"].map(option),
            claude: ["claude-unknown-9", "not-a-model"].map(option)
        ),
        OptionFixture(
            name: "pre-gpt6-terra-and-opus-alias",
            codex: ["gpt-5.6-terra-medium"].map(option),
            claude: ["opus"].map(option)
        )
    ]

    private static let providerUniverse: [AgentProviderKind] = [
        .claudeCode, .codexExec, .openCode, .antigravity
    ]

    private static var providerSets: [Set<AgentProviderKind>] {
        (0 ..< (1 << providerUniverse.count)).map { mask in
            Set(providerUniverse.enumerated().compactMap { index, provider in
                mask & (1 << index) != 0 ? provider : nil
            })
        }
    }

    private static var availabilityContexts: [AgentModelCatalog.AvailabilityContext] {
        [false, true].flatMap { claude in
            [false, true].flatMap { codex in
                [false, true].map { openCode in
                    AgentModelCatalog.AvailabilityContext(
                        claudeCodeAvailable: claude,
                        codexAvailable: codex,
                        openCodeAvailable: openCode
                    )
                }
            }
        }
    }

    private func builder(
        _ fixture: OptionFixture,
        opaqueKeys: Counter = Counter(),
        optionReads: Counter = Counter()
    ) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                opaqueKeys.value += 1
                return "key-\(opaqueKeys.value)"
            },
            modelOptions: { provider, _ in
                optionReads.value += 1
                switch provider {
                case .codexExec: return fixture.codex
                case .claudeCode: return fixture.claude
                default: return []
                }
            }
        )
    }

    func testHasAvailableTargetMatchesNonEmptyBuildForEveryInput() {
        var outcomes: Set<Bool> = []
        for fixture in Self.optionFixtures {
            let builder = builder(fixture)
            for providers in Self.providerSets {
                for availability in Self.availabilityContexts {
                    for surface in [AgentModelCatalog.AgentSelectionSurface.general, .headless] {
                        let expected = (try? builder.build(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )) != nil
                        let actual = builder.hasAvailableTarget(
                            allowedProviders: providers,
                            availability: availability,
                            surface: surface
                        )
                        XCTAssertEqual(
                            actual,
                            expected,
                            "fixture=\(fixture.name) providers=\(providers.map(\.rawValue).sorted()) availability=\(availability) surface=\(surface)"
                        )
                        outcomes.insert(actual)
                    }
                }
            }
        }
        // The grid must exercise both answers, or the equivalence above proves nothing.
        XCTAssertEqual(outcomes, [true, false])
    }

    func testHasAvailableTargetStopsAtFirstResolvedDefinitionWithoutBuildingCandidates() throws {
        let fixture = Self.optionFixtures[0]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertTrue(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        // An opaque key is minted immediately before each candidate's display name and description
        // are rendered, so zero keys means no candidate was constructed. One catalog read means the
        // probe stopped at the first eligible definition that resolved.
        XCTAssertEqual(opaqueKeys.value, 0)
        XCTAssertEqual(optionReads.value, 1)

        opaqueKeys.value = 0
        optionReads.value = 0
        let candidates = try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        )
        XCTAssertEqual(opaqueKeys.value, candidates.count)
        XCTAssertGreaterThan(optionReads.value, 1)
    }

    func testHasAvailableTargetReadsEveryEligibleDefinitionBeforeAnsweringNo() {
        let fixture = Self.optionFixtures[1]
        let opaqueKeys = Counter()
        let optionReads = Counter()
        let builder = builder(fixture, opaqueKeys: opaqueKeys, optionReads: optionReads)
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )

        XCTAssertFalse(builder.hasAvailableTarget(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        let noReads = optionReads.value
        optionReads.value = 0
        XCTAssertThrowsError(try builder.build(
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability
        ))
        XCTAssertEqual(noReads, optionReads.value)
        XCTAssertEqual(opaqueKeys.value, 0)
    }
}
