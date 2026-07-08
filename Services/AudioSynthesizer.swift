import Foundation
import AVFoundation

class AudioSynthesizer {
    static let shared = AudioSynthesizer()
    private let synthesizer = AVSpeechSynthesizer()
    // Voice lookup scans the installed-voice list and is slow enough to cause
    // a visible hitch when done on every utterance, so resolve it once.
    private let englishVoice = AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice(language: "en")

    private init() {
        // Set audio session category to ambient so it plays audio even in silent mode if needed, 
        // or just let default playback play.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    /// Pronounces the given text using TTS
    /// - Parameters:
    ///   - text: The English word or sentence to speak
    ///   - language: Voice language (default is "en-US" for TEPS)
    func speak(text: String, language: String = "en-US") {
        guard !text.isEmpty else { return }
        
        let utterance = AVSpeechUtterance(string: text)
        if language == "en-US" {
            utterance.voice = englishVoice
        } else {
            // Fall back to the cached English voice if the requested one is not installed
            utterance.voice = AVSpeechSynthesisVoice(language: language) ?? englishVoice
        }
        
        // Speed (0.5 is default average rate)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Stop any current speech before speaking new word
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        synthesizer.speak(utterance)
    }
}
