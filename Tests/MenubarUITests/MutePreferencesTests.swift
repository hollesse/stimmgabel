import XCTest
@testable import MenubarUI

// MARK: - MutePreferences Tier-1 tests (ADR 0007, ADR 0009)
//
// Uses an isolated UserDefaults suite so tests never pollute UserDefaults.standard.

final class MutePreferencesTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "test.stimmgabel.mute")!
        // Clear any state left by a previous run.
        testDefaults.removePersistentDomain(forName: "test.stimmgabel.mute")
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "test.stimmgabel.mute")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: Default values

    func test_defaults_micMuted_isFalse() {
        let prefs = MutePreferences(defaults: testDefaults)
        XCTAssertFalse(prefs.micMuted)
    }

    func test_defaults_systemAudioMuted_isFalse() {
        let prefs = MutePreferences(defaults: testDefaults)
        XCTAssertFalse(prefs.systemAudioMuted)
    }

    // MARK: Round-trip micMuted

    func test_roundTrip_micMuted_true() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.micMuted = true
        // Read back from a fresh instance using the same underlying store.
        let prefs2 = MutePreferences(defaults: testDefaults)
        XCTAssertTrue(prefs2.micMuted)
    }

    func test_roundTrip_micMuted_false_afterBeingTrue() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.micMuted = true
        prefs.micMuted = false
        let prefs2 = MutePreferences(defaults: testDefaults)
        XCTAssertFalse(prefs2.micMuted)
    }

    // MARK: Round-trip systemAudioMuted

    func test_roundTrip_systemAudioMuted_true() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.systemAudioMuted = true
        let prefs2 = MutePreferences(defaults: testDefaults)
        XCTAssertTrue(prefs2.systemAudioMuted)
    }

    func test_roundTrip_systemAudioMuted_false_afterBeingTrue() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.systemAudioMuted = true
        prefs.systemAudioMuted = false
        let prefs2 = MutePreferences(defaults: testDefaults)
        XCTAssertFalse(prefs2.systemAudioMuted)
    }

    // MARK: Independence of the two keys

    func test_muteKeys_areIndependent() {
        var prefs = MutePreferences(defaults: testDefaults)
        prefs.micMuted = true
        prefs.systemAudioMuted = false
        let prefs2 = MutePreferences(defaults: testDefaults)
        XCTAssertTrue(prefs2.micMuted)
        XCTAssertFalse(prefs2.systemAudioMuted)
    }
}
