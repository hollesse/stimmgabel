import Foundation
import AudioEngine

/// Central observable state for the menu-bar UI.
///
/// Owns `AudioPipeline`, `DriverOutputAdapter`, and `MutePreferences`.
/// On construction it reads persisted mute values and applies them to the
/// pipeline so the engine's internal state matches `UserDefaults` before any
/// consumer can attach (per ADR 0007).
///
/// All mutations must happen on the main actor (SwiftUI binding requirement).
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: - Published state

    /// Mirror of `AudioPipeline.state` — updated via `stateDidChange` callback.
    /// Setter is `internal` so tests can inject state directly without needing async callbacks.
    @Published public internal(set) var pipelineState: AudioPipelineState = .idle

    /// Whether the mic side is muted. Writing persists to `UserDefaults` and
    /// forwards to the pipeline immediately.
    @Published public var micMuted: Bool = false {
        didSet {
            preferences.micMuted = micMuted
            pipeline.setSideMute(mic: micMuted)
        }
    }

    /// Whether the system-audio side is muted. Writing persists to `UserDefaults`
    /// and forwards to the pipeline immediately.
    @Published public var systemAudioMuted: Bool = false {
        didSet {
            preferences.systemAudioMuted = systemAudioMuted
            pipeline.setSideMute(systemAudio: systemAudioMuted)
        }
    }

    // MARK: - Internals

    let pipeline: AudioPipeline
    /// Held here so the adapter (and its XPC connection / render timer) lives for
    /// the duration of the app.  `nil` in tests that don't need output.
    private let outputAdapter: DriverOutputAdapter?
    private var preferences: MutePreferences

    // MARK: - Init

    /// Production initialiser: creates a real pipeline, real adapters, and a real output adapter.
    @available(macOS 14.2, *)
    public convenience init() {
        let pipeline = AudioPipeline(
            micAdapter: MicAdapter(),
            systemAudioAdapter: SystemAudioAdapter()
        )
        let outputAdapter = DriverOutputAdapter(pipeline: pipeline)
        self.init(
            pipeline: pipeline,
            outputAdapter: outputAdapter,
            preferences: MutePreferences()
        )
    }

    /// Designated init used by both production and tests.
    ///
    /// - Parameters:
    ///   - pipeline: The audio pipeline to control.
    ///   - outputAdapter: Optional; pass `nil` in tests that don't need driver output.
    ///   - preferences: Persistence store (use an isolated suite in tests).
    public init(
        pipeline: AudioPipeline,
        outputAdapter: DriverOutputAdapter? = nil,
        preferences: MutePreferences = MutePreferences()
    ) {
        self.pipeline = pipeline
        self.outputAdapter = outputAdapter
        self.preferences = preferences

        // Restore persisted mute state — update backing properties directly to
        // avoid running didSet before the pipeline is configured.
        let savedMicMuted = preferences.micMuted
        let savedSysAudioMuted = preferences.systemAudioMuted
        _micMuted = Published(initialValue: savedMicMuted)
        _systemAudioMuted = Published(initialValue: savedSysAudioMuted)

        // Apply persisted values to the pipeline before any consumer attaches.
        pipeline.setSideMute(mic: savedMicMuted, systemAudio: savedSysAudioMuted)

        // Subscribe to pipeline state transitions (called on the state queue;
        // we hop to the main actor to update @Published).
        pipeline.stateDidChange = { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.pipelineState = newState
            }
        }
        // Snapshot current state in case a consumer already attached.
        pipelineState = pipeline.state
    }

    // MARK: - Icon system image

    /// Returns the SF Symbol name appropriate for the current state.
    ///
    /// - Idle: `waveform.slash` — engine is asleep, nothing to worry about.
    /// - Active, no mutes: `waveform` — engine running normally.
    /// - Active, any side muted: `waveform.badge.minus` — partial signal visible at a glance.
    public var menuBarIconName: String {
        switch pipelineState {
        case .idle:
            return "waveform.slash"
        case .consumerAttached:
            if micMuted || systemAudioMuted {
                return "waveform.badge.minus"
            }
            return "waveform"
        }
    }
}
