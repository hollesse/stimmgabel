import XCTest
import AVFAudio
import AudioEngine
@testable import MenubarUI

// MARK: - Fake upstream capture adapter (reuse pattern from AudioEngineTests)

private final class FakeUpstreamCaptureAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    private(set) var isRunning: Bool = false
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var deviceName: String = ""
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
}

// MARK: - AppViewModel Tier-1 tests (ADR 0009)
//
// Verifies that given engine state X the view model renders the correct icon
// and that mute toggles propagate to the pipeline.

@MainActor
final class AppViewModelTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "test.stimmgabel.viewmodel")!
        testDefaults.removePersistentDomain(forName: "test.stimmgabel.viewmodel")
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "test.stimmgabel.viewmodel")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePipeline() -> AudioPipeline {
        AudioPipeline(
            micAdapter: FakeUpstreamCaptureAdapter(),
            systemAudioAdapter: FakeUpstreamCaptureAdapter()
        )
    }

    private func makeViewModel(pipeline: AudioPipeline) -> AppViewModel {
        AppViewModel(
            pipeline: pipeline,
            outputAdapter: nil,
            preferences: MutePreferences(defaults: testDefaults)
        )
    }

    // MARK: - Icon state projection

    func test_icon_idle_noMutes_isWaveformSlash() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertEqual(vm.menuBarIconName, "waveform.slash")
    }

    func test_icon_consumerAttached_noMutes_isWaveform() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        pipeline.consumerAttached()
        vm.pipelineState = .consumerAttached // simulate callback

        XCTAssertEqual(vm.menuBarIconName, "waveform")
    }

    func test_icon_consumerAttached_micMuted_isWaveformBadgeMinus() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.pipelineState = .consumerAttached
        vm.micMuted = true

        XCTAssertEqual(vm.menuBarIconName, "waveform.badge.minus")
    }

    func test_icon_consumerAttached_systemAudioMuted_isWaveformBadgeMinus() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.pipelineState = .consumerAttached
        vm.systemAudioMuted = true

        XCTAssertEqual(vm.menuBarIconName, "waveform.badge.minus")
    }

    func test_icon_consumerAttached_bothMuted_isWaveformBadgeMinus() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.pipelineState = .consumerAttached
        vm.micMuted = true
        vm.systemAudioMuted = true

        XCTAssertEqual(vm.menuBarIconName, "waveform.badge.minus")
    }

    // MARK: - Mute propagates to pipeline

    func test_setMicMuted_true_propagatesToPipeline() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.micMuted = true

        XCTAssertTrue(pipeline.isMicMuted)
    }

    func test_setMicMuted_false_propagatesToPipeline() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.micMuted = true
        vm.micMuted = false

        XCTAssertFalse(pipeline.isMicMuted)
    }

    func test_setSystemAudioMuted_true_propagatesToPipeline() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.systemAudioMuted = true

        XCTAssertTrue(pipeline.isSystemAudioMuted)
    }

    // MARK: - Mute is persisted on toggle

    func test_setMicMuted_true_persistsToDefaults() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.micMuted = true

        let readBack = MutePreferences(defaults: testDefaults)
        XCTAssertTrue(readBack.micMuted)
    }

    func test_setSystemAudioMuted_true_persistsToDefaults() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.systemAudioMuted = true

        let readBack = MutePreferences(defaults: testDefaults)
        XCTAssertTrue(readBack.systemAudioMuted)
    }

    // MARK: - Status indicator (ADR 0009, menubar-ui-003)

    func test_consumerActive_false_whenPipelineIdle() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertFalse(vm.consumerActive)
    }

    func test_consumerActive_true_afterPipelineConsumerAttached() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        pipeline.consumerAttached()
        // Simulate the stateDidChange callback reaching the view model synchronously.
        vm.pipelineState = .consumerAttached

        XCTAssertTrue(vm.consumerActive)
    }

    func test_consumerStatusDisplayString_idle() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertEqual(vm.consumerStatusDisplayString, "Idle — no app reading")
    }

    func test_consumerStatusDisplayString_active() {
        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)
        vm.pipelineState = .consumerAttached

        XCTAssertEqual(vm.consumerStatusDisplayString, "Active")
    }

    func test_currentMicDeviceName_reflectsPipeline() {
        let pipeline = makePipeline()
        pipeline.currentMicDeviceName = "AirPods Pro"
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertEqual(vm.currentMicDeviceName, "AirPods Pro")
    }

    func test_currentSystemAudioDeviceName_reflectsPipeline() {
        let pipeline = makePipeline()
        pipeline.currentSystemAudioDeviceName = "MacBook Pro Speakers"
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertEqual(vm.currentSystemAudioDeviceName, "MacBook Pro Speakers")
    }

    // MARK: - Persisted state is restored on launch

    func test_launch_restoresMicMuteFromDefaults() {
        // Persist mic muted = true before creating the view model.
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.micMuted = true

        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        // View model should mirror what was persisted.
        XCTAssertTrue(vm.micMuted)
        // Pipeline should also reflect it immediately.
        XCTAssertTrue(pipeline.isMicMuted)
    }

    func test_launch_restoresSystemAudioMuteFromDefaults() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.systemAudioMuted = true

        let pipeline = makePipeline()
        let vm = makeViewModel(pipeline: pipeline)

        XCTAssertTrue(vm.systemAudioMuted)
        XCTAssertTrue(pipeline.isSystemAudioMuted)
    }
}
