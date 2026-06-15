import XCTest
import CoreAudio
@testable import AudioEngine

/// Unit tests for `DefaultDeviceMonitor` (audio-engine-008).
///
/// Two flavours:
/// 1. Plumbing tests that use the `testingMicName:` initializer + the
///    `_setNamesForTesting` seam — no live HAL access, deterministic.
/// 2. Live tests that exercise the real HAL — gated on actual hardware
///    behaviour (a developer Mac is expected to have a default input and
///    a default output device).
final class DefaultDeviceMonitorTests: XCTestCase {

    // MARK: - Free helper

    func test_readDefaultDeviceName_input_returnsNonEmptyOnDeveloperMac() {
        // Acceptance criterion: a developer Mac always has a default input.
        // Empty string only when no hardware exists — not the case in CI on a
        // real machine. If this ever fails in a sandboxed CI env, gate the
        // assertion on hardware presence.
        let name = readDefaultDeviceName(
            forSelector: kAudioHardwarePropertyDefaultInputDevice
        )
        XCTAssertFalse(name.isEmpty,
            "Default input device should resolve to a non-empty name on a real Mac")
    }

    func test_readDefaultDeviceName_output_returnsNonEmptyOnDeveloperMac() {
        let name = readDefaultDeviceName(
            forSelector: kAudioHardwarePropertyDefaultOutputDevice
        )
        XCTAssertFalse(name.isEmpty,
            "Default output device should resolve to a non-empty name on a real Mac")
    }

    // MARK: - Initial state

    func test_init_readsCurrentDefaultDevices() {
        // With the standard initializer the monitor must read both device
        // names eagerly so the UI sees them before any consumer attaches.
        let monitor = DefaultDeviceMonitor()
        XCTAssertFalse(monitor.currentMicDeviceName.isEmpty,
            "Mic name must be populated on init (acceptance: visible in idle state)")
        XCTAssertFalse(monitor.currentSystemAudioDeviceName.isEmpty,
            "System audio name must be populated on init (acceptance: visible in idle state)")
    }

    func test_testInit_usesSuppliedNames() {
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Test Mic",
            testingSystemAudioName: "Test Output"
        )
        XCTAssertEqual(monitor.currentMicDeviceName, "Test Mic")
        XCTAssertEqual(monitor.currentSystemAudioDeviceName, "Test Output")
    }

    // MARK: - Change notification

    func test_setNames_firesOnChange_whenMicChanges() {
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Old Mic",
            testingSystemAudioName: "Old Output"
        )
        var fired = 0
        monitor.onChange = { fired += 1 }
        monitor._setNamesForTesting(mic: "New Mic", sys: nil)
        XCTAssertEqual(monitor.currentMicDeviceName, "New Mic")
        XCTAssertEqual(monitor.currentSystemAudioDeviceName, "Old Output")
        XCTAssertEqual(fired, 1, "onChange must fire when the mic name changes")
    }

    func test_setNames_firesOnChange_whenSysChanges() {
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Old Mic",
            testingSystemAudioName: "Old Output"
        )
        var fired = 0
        monitor.onChange = { fired += 1 }
        monitor._setNamesForTesting(mic: nil, sys: "New Output")
        XCTAssertEqual(monitor.currentMicDeviceName, "Old Mic")
        XCTAssertEqual(monitor.currentSystemAudioDeviceName, "New Output")
        XCTAssertEqual(fired, 1, "onChange must fire when the sys audio name changes")
    }

    func test_setNames_doesNotFire_whenNothingChanges() {
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Mic",
            testingSystemAudioName: "Out"
        )
        var fired = 0
        monitor.onChange = { fired += 1 }
        monitor._setNamesForTesting(mic: "Mic", sys: "Out")
        XCTAssertEqual(fired, 0,
            "onChange must not fire when the names are unchanged (no spurious UI ticks)")
    }

    // MARK: - Real-HAL property-listener round-trip

    /// Verifies the monitor stays consistent with the live HAL by performing
    /// a refresh after init. On a real Mac the names should match the
    /// underlying free-function reader.
    func test_refresh_matchesLiveHAL() {
        let monitor = DefaultDeviceMonitor()
        monitor._refreshForTesting()
        XCTAssertEqual(monitor.currentMicDeviceName,
                       readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultInputDevice))
        XCTAssertEqual(monitor.currentSystemAudioDeviceName,
                       readDefaultDeviceName(forSelector: kAudioHardwarePropertyDefaultOutputDevice))
    }

    // MARK: - Lifecycle

    func test_init_andDeinit_doesNotCrash() {
        // Smoke test that listener install + remove on dealloc works.
        var monitor: DefaultDeviceMonitor? = DefaultDeviceMonitor()
        XCTAssertNotNil(monitor)
        monitor = nil
    }
}

/// Tests that `AudioPipeline` delegates device names to the injected monitor.
final class AudioPipelineDeviceNameTests: XCTestCase {

    private func makePipeline(monitor: DefaultDeviceMonitor) -> (AudioPipeline, FakeUpstreamCaptureAdapter, FakeUpstreamCaptureAdapter) {
        let sys = FakeUpstreamCaptureAdapter()
        let mic = FakeUpstreamCaptureAdapter()
        let pipeline = AudioPipeline(systemAudioAdapter: sys,
                                     micAdapter: mic,
                                     deviceMonitor: monitor)
        return (pipeline, sys, mic)
    }

    func test_idlePipeline_exposesMonitorMicName() {
        // Acceptance: names visible when pipeline is idle (no consumer).
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Built-in Mic",
            testingSystemAudioName: "Built-in Speakers"
        )
        let (pipeline, _, _) = makePipeline(monitor: monitor)
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertEqual(pipeline.currentMicDeviceName, "Built-in Mic")
        XCTAssertEqual(pipeline.currentSystemAudioDeviceName, "Built-in Speakers")
    }

    func test_monitorChange_firesPipelineDeviceNamesDidChange() {
        // Acceptance: switching the default mid-session fires the UI callback.
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Mic A",
            testingSystemAudioName: "Out A"
        )
        let (pipeline, _, _) = makePipeline(monitor: monitor)
        var fired = 0
        pipeline.deviceNamesDidChange = { fired += 1 }
        monitor._setNamesForTesting(mic: "AirPods", sys: nil)
        XCTAssertEqual(pipeline.currentMicDeviceName, "AirPods")
        XCTAssertEqual(fired, 1,
            "Pipeline must forward DefaultDeviceMonitor change to deviceNamesDidChange")
    }

    func test_consumerAttached_namesStillReflectMonitor() {
        // Acceptance: no regression vs. menubar-ui-003 — once a consumer
        // attaches, the displayed names continue to reflect the system
        // default (which the adapter just started on too).
        let monitor = DefaultDeviceMonitor(
            testingMicName: "Built-in Mic",
            testingSystemAudioName: "Built-in Speakers"
        )
        let (pipeline, _, _) = makePipeline(monitor: monitor)
        pipeline.consumerAttached()
        // micAdapter.deviceName remains "" (FakeUpstreamCaptureAdapter),
        // but the pipeline must NOT report the adapter's value — it must
        // delegate to the monitor.
        XCTAssertEqual(pipeline.currentMicDeviceName, "Built-in Mic")
        XCTAssertEqual(pipeline.currentSystemAudioDeviceName, "Built-in Speakers")
    }
}
