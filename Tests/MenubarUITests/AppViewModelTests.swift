import XCTest
import AVFAudio
import AudioEngine
@testable import MenubarUI

private final class FakeAdapter: UpstreamCaptureAdapter, @unchecked Sendable {
    private(set) var isRunning: Bool = false
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var deviceName: String = ""
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
final class AppViewModelTests: XCTestCase {

    private func makePipeline(deviceName: String = "",
                              monitor: DefaultDeviceMonitor = DefaultDeviceMonitor()) -> AudioPipeline {
        let adapter = FakeAdapter()
        adapter.deviceName = deviceName
        let mic = FakeAdapter()
        return AudioPipeline(systemAudioAdapter: adapter,
                             micAdapter: mic,
                             deviceMonitor: monitor)
    }

    // MARK: - Icon

    // menubar-ui-006: SF Symbols ("waveform.slash" / "waveform") replaced with
    // custom Asset-Catalog assets ("MenubarIdle" / "MenubarActive").
    // The wiring under test is unchanged — idle vs. consumer-attached still
    // map 1:1 to the two asset names.

    func test_icon_idle_isMenubarIdle() {
        let vm = AppViewModel(pipeline: makePipeline())
        XCTAssertEqual(vm.menuBarIconName, "MenubarIdle")
    }

    func test_icon_consumerAttached_isMenubarActive() {
        let vm = AppViewModel(pipeline: makePipeline())
        vm.pipelineState = .consumerAttached
        XCTAssertEqual(vm.menuBarIconName, "MenubarActive")
    }

    // MARK: - Status

    func test_consumerActive_false_whenIdle() {
        XCTAssertFalse(AppViewModel(pipeline: makePipeline()).consumerActive)
    }

    func test_consumerActive_true_whenAttached() {
        let vm = AppViewModel(pipeline: makePipeline())
        vm.pipelineState = .consumerAttached
        XCTAssertTrue(vm.consumerActive)
    }

    func test_consumerStatusDisplayString_idle() {
        XCTAssertEqual(AppViewModel(pipeline: makePipeline()).consumerStatusDisplayString,
                       "Idle — no app reading")
    }

    func test_consumerStatusDisplayString_active() {
        let vm = AppViewModel(pipeline: makePipeline())
        vm.pipelineState = .consumerAttached
        XCTAssertEqual(vm.consumerStatusDisplayString, "Active")
    }

    func test_currentSystemAudioDeviceName_reflectsPipeline() {
        // Device names are owned by DefaultDeviceMonitor (audio-engine-008), so
        // we inject one with a forced name to assert the pipeline delegates.
        let monitor = DefaultDeviceMonitor()
        monitor._setNamesForTesting(mic: nil, sys: "MacBook Pro Speakers")
        let pipeline = makePipeline(monitor: monitor)
        let vm = AppViewModel(pipeline: pipeline)
        XCTAssertEqual(vm.currentSystemAudioDeviceName, "MacBook Pro Speakers")
    }

    // MARK: - sysAudioGain

    func test_sysAudioGain_defaultIsOne() {
        let vm = AppViewModel(pipeline: makePipeline())
        XCTAssertEqual(vm.sysAudioGain, 1.0, accuracy: 1e-5,
                       "sysAudioGain must default to 1.0 on every app start")
    }

    func test_sysAudioGain_setOnViewModel_updatesPipeline() {
        let pipeline = makePipeline()
        let vm = AppViewModel(pipeline: pipeline)
        vm.sysAudioGain = 0.5
        XCTAssertEqual(pipeline.sysAudioGain, 0.5, accuracy: 1e-5,
                       "Setting sysAudioGain on AppViewModel must propagate to pipeline")
    }

    // MARK: - micGain

    func test_micGain_defaultIsThree() {
        let vm = AppViewModel(pipeline: makePipeline())
        XCTAssertEqual(vm.micGain, 3.0, accuracy: 1e-5,
                       "micGain must default to 3.0 on every app start")
    }

    func test_micGain_setOnViewModel_updatesPipeline() {
        let pipeline = makePipeline()
        let vm = AppViewModel(pipeline: pipeline)
        vm.micGain = 1.5
        XCTAssertEqual(pipeline.micGain, 1.5, accuracy: 1e-5,
                       "Setting micGain on AppViewModel must propagate to pipeline")
    }
}
