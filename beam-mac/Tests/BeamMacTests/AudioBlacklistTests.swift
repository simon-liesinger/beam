import Testing
@testable import BeamMacCore

@Suite("Audio Mute Blacklist")
struct AudioBlacklistTests {

    // MARK: - Chrome (shares one audio process across all windows)

    @Test func chromeNotMutedWhenOtherWindowsOpen() {
        #expect(!AudioCapturer.shouldMute(
            bundleID: "com.google.Chrome",
            appWindowCount: 3,
            beamedWindowCount: 1
        ))
    }

    @Test func chromeNotMutedTwoWindowsOneBeamed() {
        #expect(!AudioCapturer.shouldMute(
            bundleID: "com.google.Chrome",
            appWindowCount: 2,
            beamedWindowCount: 1
        ))
    }

    @Test func chromeMutedWhenOnlyWindowIsBeamed() {
        #expect(AudioCapturer.shouldMute(
            bundleID: "com.google.Chrome",
            appWindowCount: 1,
            beamedWindowCount: 1
        ))
    }

    @Test func chromeMutedWhenAllWindowsBeamed() {
        #expect(AudioCapturer.shouldMute(
            bundleID: "com.google.Chrome",
            appWindowCount: 3,
            beamedWindowCount: 3
        ))
    }

    // MARK: - Non-blacklisted apps always muted

    @Test func safariAlwaysMuted() {
        #expect(AudioCapturer.shouldMute(
            bundleID: "com.apple.Safari",
            appWindowCount: 5,
            beamedWindowCount: 1
        ))
    }

    @Test func unknownAppAlwaysMuted() {
        #expect(AudioCapturer.shouldMute(
            bundleID: "com.example.someapp",
            appWindowCount: 2,
            beamedWindowCount: 1
        ))
    }

    // MARK: - Blacklist membership

    @Test func chromeIsInBlacklist() {
        #expect(AudioCapturer.muteBlacklist.contains("com.google.Chrome"))
    }

    @Test func safariNotInBlacklist() {
        #expect(!AudioCapturer.muteBlacklist.contains("com.apple.Safari"))
    }

    // MARK: - Edge case

    @Test func zeroWindowsDoesNotCrash() {
        // appWindowCount == beamedWindowCount == 0: not "more unbeamed windows", so mute
        #expect(AudioCapturer.shouldMute(
            bundleID: "com.google.Chrome",
            appWindowCount: 0,
            beamedWindowCount: 0
        ))
    }
}
