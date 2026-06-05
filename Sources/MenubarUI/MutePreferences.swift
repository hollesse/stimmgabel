import Foundation

/// Persists the per-side mute state in `UserDefaults`.
///
/// ADR 0007: keys `com.innoq.stimmgabel.muteMicSide` and
/// `com.innoq.stimmgabel.muteSystemAudioSide`. Default value for both is `false`.
///
/// On app launch, read from `MutePreferences(defaults: .standard)` and apply
/// the values to `AudioPipeline` before any consumer can attach.
public struct MutePreferences {

    // MARK: - UserDefaults keys

    private enum Keys {
        static let micMuted = "com.innoq.stimmgabel.muteMicSide"
        static let systemAudioMuted = "com.innoq.stimmgabel.muteSystemAudioSide"
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Init

    /// Creates a `MutePreferences` backed by the given `UserDefaults` store.
    ///
    /// Pass `UserDefaults.standard` in production; pass an isolated suite in tests
    /// (ADR 0009 Tier-1 rule).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Properties

    /// Whether the mic side is muted. Writes are persisted immediately.
    public var micMuted: Bool {
        get { defaults.bool(forKey: Keys.micMuted) }
        set { defaults.set(newValue, forKey: Keys.micMuted) }
    }

    /// Whether the system-audio side is muted. Writes are persisted immediately.
    public var systemAudioMuted: Bool {
        get { defaults.bool(forKey: Keys.systemAudioMuted) }
        set { defaults.set(newValue, forKey: Keys.systemAudioMuted) }
    }
}
