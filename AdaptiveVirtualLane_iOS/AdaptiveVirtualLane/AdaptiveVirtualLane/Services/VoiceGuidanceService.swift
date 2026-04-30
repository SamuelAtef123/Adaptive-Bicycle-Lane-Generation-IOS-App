import AVFoundation

final class VoiceGuidanceService {

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenText: String = ""
    private var lastSpokenTime: Date = .distantPast
    private let minInterval: TimeInterval = 3.0   // don't repeat within 3s

    func speak(_ text: String, force: Bool = false) {
        let now = Date()
        guard force || (text != lastSpokenText || now.timeIntervalSince(lastSpokenTime) > minInterval) else { return }

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate   = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.volume = 1.0
        utterance.voice  = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)

        lastSpokenText = text
        lastSpokenTime = now
    }

    // MARK: - Intersection Voice Cues

    func announceApproaching(_ maneuver: ManeuverType) {
        let text: String
        switch maneuver {
        case .goStraight: text = "Continue straight ahead"
        case .turnLeft:   text = "Turn left ahead"
        case .turnRight:  text = "Turn right ahead"
        case .unknown:    return
        }
        speak(text)
    }

    func announceAtIntersection(_ maneuver: ManeuverType) {
        let text: String
        switch maneuver {
        case .goStraight: text = "Go straight"
        case .turnLeft:   text = "Turn left now"
        case .turnRight:  text = "Turn right now"
        case .unknown:    return
        }
        speak(text, force: true)
    }

    func announceNarrowRoad() {
        speak("Warning: narrow road ahead. Proceed with caution.")
    }

    func announceObstacleAhead() {
        speak("Obstacle detected ahead.")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
