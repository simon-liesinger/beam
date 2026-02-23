# Beam - Cross-Platform Window Teleportation

## Context

Build an app that lets you "beam" windows between devices on the same LAN - select a window, send it to another device, and it disappears from the sender and appears interactively on the receiver. Like the holographic tablets from Avatar. Targets macOS and Android.

## Key Architecture Decisions

1. **Start Mac-to-Mac** - de-risks the hardest unknowns (ScreenCaptureKit, CGEvent injection, window hiding) before adding Android
2. **Native per platform** - Swift/SwiftUI for Mac, Kotlin/Compose for Android. The core work (capture, encode, input injection) is deeply OS-specific; a cross-platform framework would just add friction
3. **No KMP for MVP** - the shared protocol is ~200 lines of JSON messages + RTP packets, simpler to implement twice than to bridge
4. **Custom H.264 over UDP** (not WebRTC) - WebRTC's ICE/DTLS/SRTP is overkill for LAN. Custom gives us 20-40ms latency vs 30-80ms
5. **mDNS/Bonjour for discovery** - native on both platforms (`NetService` on Mac, `NsdManager` on Android), fully interoperable
6. **Distribute outside app stores** - Mac needs Accessibility permission (can't be sandboxed), Android uses AccessibilityService (Play Store restrictive)

## The "Hide Window" Trick

### macOS (spike-validated)
**Constraint**: ScreenCaptureKit **pauses** when a window is minimized, Cmd+H hidden, OR occluded by another window.
**Solution**: Create a **CGVirtualDisplay** (private API) positioned at the bottom-left corner of the display arrangement, then move windows there via AXUIElement. ScreenCaptureKit continues capturing at full 29fps. Windows are completely invisible to the user.

**Virtual display details:**
- Created via `CGVirtualDisplay`/`CGVirtualDisplayDescriptor` private API (well-documented by KhaosT/FluffyDisplay/Chromium)
- Positioned at bottom-left corner with minimal shared edge (cursor nearly unreachable, CMD-Tab/Spotlight stay on main display)
- Start small, grow on demand — `applySettings` can resize a live display without recreating it
- Stack beamed windows vertically to avoid occlusion (which kills capture even off-screen)
- Display config uses `.forSession` so it doesn't persist after app exit
- **Important**: windows must not overlap each other on the virtual display (occlusion = 0fps)

### Android (platform limitation - tiered approach)
**Constraint**: Android doesn't render backgrounded apps, so MediaProjection capture goes stale/black when the captured app leaves the foreground. The user MUST be able to continue using their phone after beaming.

**Tier 1 - Split-screen (MVP)**: Use AccessibilityService (which we already need for input injection) to trigger `GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN`. The beamed app stays in one half (still rendering, still captured), while the user works in the other half. Not perfect (app takes half the screen) but the user can fully multitask.

**Tier 2 - Freeze + resume**: If the user fully backgrounds the beamed app (exits split-screen), the stream freezes on the last frame. The receiver sees a "paused" indicator. A persistent notification on the sender says "Beam paused - tap to resume." Input events from the receiver are queued and replayed when the stream resumes. This is the fallback, not the default.

**Tier 3 - VirtualDisplay (future)**: Android 15+ desktop windowing mode and VirtualDisplay APIs may allow running an app on a non-physical display. This would enable true background beaming but requires newer Android versions and isn't reliable across OEMs yet.

## Protocol

- **Discovery**: mDNS service type `_beam._tcp.` with TXT records (version, platform, name, device ID)
- **Control channel**: TCP, length-prefixed JSON messages (beam_offer, beam_accept, input events, beam_end, ping)
- **Video channel**: UDP, lightweight RTP-like packets (12-byte header: seq, timestamp, flags, fragment info + H.264 NAL data)
- **Input events**: Normalized coordinates (0-1), platform-agnostic key codes, sent over TCP control channel

## Project Structure

```
beam/
  beam-mac/                          # Swift/SwiftUI macOS app
    Sources/
      BeamApp.swift                  # App entry point
      Discovery/BonjourBrowser.swift # mDNS advertise + browse
      Capture/WindowCapturer.swift   # ScreenCaptureKit per-window capture
      Capture/WindowHider.swift      # CGVirtualDisplay + AXUIElement positioning
      Capture/WindowPicker.swift     # Window list from SCShareableContent
      Streaming/H264Encoder.swift    # VTCompressionSession hardware encode
      Streaming/H264Decoder.swift    # VTDecompressionSession hardware decode
      Streaming/RtpSender.swift      # UDP packetization + send
      Streaming/RtpReceiver.swift    # UDP receive + frame reassembly
      Input/InputInjector.swift      # CGEventPostToPid for mouse/keyboard, AX scroll bar + Page Down fallback for scroll
      Input/RemoteInputHandler.swift # Capture NSEvents on receiver window
      Rendering/StreamView.swift     # AVSampleBufferDisplayLayer renderer
      Network/TCPControlChannel.swift
      Network/UDPVideoChannel.swift
      UI/MainView.swift              # Device list + window picker
      UI/BeamingView.swift           # "Beamed to {device}" sender status
      UI/ReceivingView.swift         # Borderless window showing stream

  beam-android/                      # Kotlin/Compose Android app
    src/main/java/com/beam/android/
      discovery/NsdDiscoveryManager.kt
      capture/MediaProjectionManager.kt
      capture/CaptureService.kt      # Foreground service
      streaming/H264Encoder.kt       # MediaCodec encoder
      streaming/H264Decoder.kt       # MediaCodec decoder
      streaming/RtpSender.kt
      streaming/RtpReceiver.kt
      input/InputInjectorService.kt  # AccessibilityService
      input/RemoteInputHandler.kt
      network/TcpControlChannel.kt
      session/BeamSession.kt
      ui/DeviceListScreen.kt
```

## Implementation Phases

Each task is labeled: **[OPUS]** = needs Opus (novel API integration, tricky bugs, architecture decisions), **[SONNET]** = Sonnet can handle (well-defined scope, standard patterns, clear spec).

### Phase 0: Technical Spikes ✅ COMPLETE

1. ~~**[OPUS] ScreenCaptureKit spike**~~ **DONE** - captures at 29.7fps, works with CommandLineTools (no Xcode needed). Code at `spikes/screen-capture/`.
2. ~~**[OPUS] CGEvent injection spike**~~ **DONE** - code at `spikes/cgevent-injection/`. Results:
   - **Mouse** (move, click, drag): WORKS via `postToPid`. Tested on Terminal, Chrome, Signal.
   - **Keyboard** (keystrokes, Unicode text): WORKS via `postToPid` with Unicode string injection.
   - **Scroll wheel**: `postToPid` does NOT deliver scroll events (macOS limitation). Workarounds:
     - **AX scroll bar value** (0.0-1.0): works for native AppKit apps with AXScrollArea (e.g. Terminal). Zero user interference, works off-screen.
     - **Page Down/Up keys** via `postToPid`: universal fallback, works on all apps.
     - **Mouse drag on scroll bar**: always works since mouse events work via `postToPid`. Remote user drags the scroll bar.
     - **Arrow keys**: work if no text field is focused.
   - **Event source state**: `CGEventSource(.privateState)` lets us distinguish remote events from local user input.
   - **Window control** via AXUIElement: raise, focus, move position all work.
3. **[OPUS] VideoToolbox encode/decode spike** - DONE. Hardware H.264 encode → UDP packetize → receive → decode → render. Key findings:
   - **29.3fps sustained** at 1470x918, matching target 30fps. Zero packet loss on loopback.
   - **14-16ms average latency** (encode + UDP + reassemble + decode), well under our 20-40ms budget.
   - **VTCompressionSession**: use per-frame `outputHandler` variant of `VTCompressionSessionEncodeFrame` (session-level C callback + refcon is painful in Swift).
   - **VTDecompressionSession**: use per-frame `completionHandler` on `VTDecompressionSessionDecodeFrame` (includes `taggedBuffers` parameter in Swift API).
   - **AVCC format**: VideoToolbox outputs 4-byte-length-prefixed NAL units, must extract and repackage for transport.
   - **SPS/PPS**: extracted from encoder format description, must be sent before keyframes for decoder to create session.
   - **AVSampleBufferDisplayLayer**: works well as render target, just enqueue CMSampleBuffers.
   - **UDP**: NWListener had reliability issues across runs; BSD sockets with SO_REUSEPORT are more reliable.
   - **RTP-like header**: 12 bytes (seq, timestamp, flags, fragment index/count). NALs fragmented into 1400-byte MTU chunks.
   - **ScreenCaptureKit**: only sends frames when content changes (bandwidth-efficient). Must stop stream cleanly (SIGINT handler) or daemon enters -3805 error state.
   - Code at `spikes/videotoolbox/`
4. **[OPUS] Window hiding spike** - DONE. Tested 6 hiding strategies + virtual display approach. Key findings:
   - **Occluded/minimized/hidden**: all BLOCKED (0-0.5fps). ScreenCaptureKit stops rendering.
   - **Off-screen via AXUIElement**: WORKS but macOS **clamps** positions to display bounds (requesting x=-10000 yields ~x=-1430). Window edge pokes in.
   - **CGVirtualDisplay** (private API): **WORKS perfectly** - 29fps capture, window completely invisible.
     - Create virtual display, position at bottom-left corner of display arrangement
     - Move windows there via AXUIElement — ScreenCaptureKit keeps streaming
     - `applySettings` can resize a live display (start small, grow on demand)
     - Bottom-left corner placement prevents CMD-Tab/Spotlight from appearing on it
     - Stack windows vertically to avoid occlusion
   - **Critical insight**: windows must NOT overlap on the virtual display — occlusion kills capture even off-screen.
   - Code at `spikes/window-hiding/`

### Phase 1: Mac-to-Mac MVP

**Week 2 - Foundation:**
- **[SONNET]** Create Swift Package project with SwiftUI app skeleton (BeamApp.swift, Package.swift)
- **[SONNET]** Implement Bonjour discovery - `BonjourBrowser.swift` (advertise + browse `_beam._tcp.`). Standard NetService API, well-documented.
- **[SONNET]** Implement window picker UI - `WindowPicker.swift` (list windows from `SCShareableContent`). Builds directly on spike code.
- **[SONNET]** Implement `WindowCapturer.swift` - wrap SCStream from spike into a reusable class. Straightforward refactor.

**Week 3 - Streaming pipeline:**
- **[OPUS]** H264Encoder.swift - VTCompressionSession wrapper. Needs careful NAL unit extraction, SPS/PPS parameter set handling, low-latency tuning.
- **[OPUS]** H264Decoder.swift - VTDecompressionSession wrapper. Must handle format description creation from SPS/PPS, session invalidation on resolution change.
- **[SONNET]** RtpSender.swift - fragment NAL units into UDP packets with the 12-byte header format. Pure data framing, well-specified.
- **[SONNET]** RtpReceiver.swift + FrameAssembler - receive UDP packets, reassemble by sequence number. Pure data reassembly logic.
- **[OPUS]** StreamView.swift - AVSampleBufferDisplayLayer or Metal rendering of decoded frames. Needs timing/display sync right.

**Week 4 - Input + session management:**
- **[SONNET]** TCPControlChannel.swift - NWListener/NWConnection, length-prefixed JSON, heartbeat. Standard networking code.
- **[OPUS]** InputInjector.swift - CGEvent creation + posting with source state trick to distinguish remote/local events. Novel API.
- **[SONNET]** RemoteInputHandler.swift - capture NSEvents on the receiver window, normalize to 0-1 coords, serialize as JSON. Straightforward event handling.
- **[OPUS]** WindowHider.swift - CGVirtualDisplay creation/positioning + AXUIElement window moves + live resize. Private API + Accessibility integration.
- **[SONNET]** BeamSession.swift - state machine coordinating all components. Well-defined states, standard pattern.
- **[SONNET]** UI views (MainView, BeamingView, ReceivingView) - standard SwiftUI, builds on data from other components.

### Phase 2: Polish

- **[SONNET]** Permission onboarding flow - check `CGPreflightScreenCaptureAccess()`, `AXIsProcessTrusted()`, show instructions. Standard UI flow.
- **[SONNET]** Error handling: window closed, app quit, network drop - respond to notifications/callbacks, clean up session.
- **[SONNET]** Auto-reconnect (3 attempts, keyframe request on resume) - standard retry logic.
- **[OPUS]** Adaptive bitrate - monitor RTT from ping/pong, dynamically adjust VTCompressionSession bitrate. Needs tuning.
- **[SONNET]** Multi-monitor coordinate math - NSScreen geometry calculations.

### Phase 3: Android

- **[SONNET]** Android project setup - Gradle, Compose, permissions, manifest.
- **[SONNET]** NSD discovery - NsdDiscoveryManager.kt. Same `_beam._tcp.` service, standard Android API.
- **[OPUS]** MediaProjection capture + foreground service - CaptureService.kt, MediaProjectionManager.kt. Android 14+ single-app mode, visibility callbacks.
- **[OPUS]** MediaCodec encode/decode - H264Encoder.kt, H264Decoder.kt. Hardware codec setup, surface input/output modes.
- **[SONNET]** RTP sender/receiver (Kotlin) - same packet format as Mac, DatagramSocket + coroutines. Port of well-defined spec.
- **[SONNET]** TCP control channel (Kotlin) - TcpControlChannel.kt. Port of the Mac implementation.
- **[OPUS]** AccessibilityService for input injection + split-screen - InputInjectorService.kt. dispatchGesture(), GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN.
- **[SONNET]** UI screens (Compose) - DeviceListScreen, BeamingScreen, ReceivingScreen.
- **[SONNET]** GitHub Actions CI - reuse ClaudeCodeMobile pattern.

### Phase 4: Cross-Platform

- **[SONNET]** Key code translation table - mapping between Mac/Android key codes. Data table, well-specified.
- **[SONNET]** Touch-to-mouse / mouse-to-touch mapping - coordinate translation logic.
- **[SONNET]** Resolution negotiation in beam_offer/beam_accept - add fields to existing protocol messages.
- **[SONNET]** Orientation handling for Android portrait/landscape.

## Task Summary

| Category | Opus | Sonnet | Total |
|----------|------|--------|-------|
| Phase 0 (Spikes) | 0 | 0 | 0 (done) |
| Phase 1 (Mac MVP) | 5 | 7 | 12 |
| Phase 2 (Polish) | 1 | 4 | 5 |
| Phase 3 (Android) | 3 | 6 | 9 |
| Phase 4 (Cross-plat) | 0 | 4 | 4 |
| **Total** | **10** | **21** | **31** |

**Sonnet handles ~68% of tasks.** The Opus tasks are concentrated in: codec encode/decode (VideoToolbox/MediaCodec), input injection (CGEvent/AccessibilityService), window hiding (CGVirtualDisplay), and streaming display (frame timing).

## Key Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| ScreenCaptureKit stops on certain "hidden" states | **Critical** | Phase 0 spike tests all hiding strategies |
| CGEventPostToPid doesn't work for some apps (Electron, etc.) | High | Phase 0 spike tests diverse apps |
| Android: app capture pauses when fully backgrounded | High | Split-screen as default, freeze+resume as fallback |
| Android AccessibilityService setup is confusing for users | Medium | Clear onboarding with screenshots |
| Android: some apps don't support split-screen | Medium | Fall back to freeze+resume mode for those apps |
| UDP packet loss on congested WiFi | Medium | Keyframe-on-loss + optional FEC later |

## Verification

- **Spikes**: each produces a standalone runnable proof
- **Mac-to-Mac**: beam a Safari window between two Mac processes, scroll and click links on receiver
- **Android**: beam an app between two Android devices, tap and interact
- **Cross-platform**: beam from Mac to Android and vice versa
- **Edge cases**: kill sender mid-stream (receiver recovers), kill receiver (sender restores window), beam 4K window (performance), rapid beam/recall cycles

## References

- [Sunshine](https://github.com/LizardByte/Sunshine) - open source game streaming host, closest architecture reference
- [Moonlight](https://github.com/moonlight-stream/moonlight-qt) - game streaming client, decode + render + input
- [scrcpy](https://github.com/Genymobile/scrcpy) - Android screen mirror, clean H.264 protocol
- [multi.app blog](https://multi.app/blog/building-a-macos-remote-control-engine) - macOS CGEvent injection architecture
- [LocalSend protocol](https://github.com/localsend/protocol) - mDNS + TCP discovery pattern

## Current State

- **Spike 1 (ScreenCaptureKit)**: PASSED - 29.7fps capture, code at `spikes/screen-capture/`
- **Spike 2 (CGEvent injection)**: PASSED (with scroll caveat) - mouse/keyboard work via `postToPid`, scroll wheel doesn't but has viable workarounds (AX scroll bar, Page Down keys, mouse drag). Code at `spikes/cgevent-injection/`
- **Spike 3 (VideoToolbox encode/decode)**: PASSED - 29.3fps, 14-16ms latency, zero packet loss. Full pipeline: capture → H.264 encode → UDP packetize → receive → decode → AVSampleBufferDisplayLayer render. Code at `spikes/videotoolbox/`
- **Spike 4 (Window hiding)**: PASSED - CGVirtualDisplay at bottom-left corner, windows moved there via AXUIElement. Full 29fps capture, completely invisible. Live resize works. Code at `spikes/window-hiding/`
- **All 4 spikes complete. Phase 0 done.** Ready for Phase 1 (Mac-to-Mac MVP).
- **No Xcode needed** - CommandLineTools + Swift 6.0.2 is sufficient
- **Screen Recording permission**: Already granted
- **Accessibility permission**: Already granted
