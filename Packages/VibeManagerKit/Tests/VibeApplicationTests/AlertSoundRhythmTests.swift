import Foundation
import Testing

@testable import VibeApplication

@Suite("The rhythm of an alert sound (#555)")
struct AlertSoundRhythmTests {
  private static let rate = 44_100

  /// Silence, with a short tone at each of `starts`.
  private func clicks(at starts: [Double], length: Double = 0.03, duration: Double = 1.2)
    -> [Float]
  {
    var samples = [Float](repeating: 0, count: Int(duration * Double(Self.rate)))
    for start in starts {
      let first = Int(start * Double(Self.rate))
      for index in first..<min(samples.count, first + Int(length * Double(Self.rate))) {
        samples[index] = Float(sin(2 * Double.pi * 880 * Double(index) / Double(Self.rate)))
      }
    }
    return samples
  }

  private func voice(gain: Double = 1, starts: [Double]) -> AlertSoundRecipe.Voice {
    AlertSoundRecipe.Voice(
      wave: .sine, gain: gain, attack: 0.005, decay: 0.05, sustain: 0.5, release: 0.1,
      notes: starts.map { AlertSoundRecipe.Note(start: $0, length: 0.1, pitch: "A4") })
  }

  @Test("A recipe taps at each note; a chord is one tap, a muted voice none")
  func recipe() {
    let recipe = AlertSoundRecipe(
      name: "Test",
      voices: [
        voice(starts: [0, 0.25, 0.5]),
        voice(starts: [0.27]),
        voice(gain: 0, starts: [0.1]),
      ])
    #expect(AlertSoundRhythm(recipe: recipe).taps == [0, 0.25, 0.5])
  }

  @Test("Taps in order, never too close, never too many, never none")
  func normalized() {
    #expect(AlertSoundRhythm(taps: [0.5, 0, 0.05, .nan, -1]).taps == [0, 0.5])
    #expect(AlertSoundRhythm(taps: []).taps == [0])
    let many = AlertSoundRhythm(taps: (0..<100).map { Double($0) * 0.2 })
    #expect(many.taps.count == AlertSoundRhythm.maximumTaps)
  }

  @Test("Spaced for a trackpad that loses close taps")
  func spaced() {
    let rhythm = AlertSoundRhythm(taps: [0, 0.15, 0.3, 0.5, 1])
    #expect(rhythm.spaced(by: 0.4).taps == [0, 0.5, 1])
  }

  @Test("Samples tap at each attack")
  func attacks() throws {
    let rhythm = AlertSoundRhythm(samples: clicks(at: [0.1, 0.4, 0.8]), sampleRate: Self.rate)
    try #require(rhythm.taps.count == 3)
    for (tap, start) in zip(rhythm.taps, [0.1, 0.4, 0.8]) {
      #expect(abs(tap - start) <= 0.02)
    }
  }

  @Test("Silence, or a tone without attacks, is a single tap")
  func single() {
    #expect(
      AlertSoundRhythm(samples: [Float](repeating: 0, count: 4410), sampleRate: Self.rate)
        == .single)
    let hum = (0..<Self.rate).map { Float(sin(2 * Double.pi * 220 * Double($0) / 44_100)) }
    #expect(AlertSoundRhythm(samples: hum, sampleRate: Self.rate) == .single)
  }

  @Test("A shipped sound feels the same from its recipe as from its samples")
  func shipped() {
    for sound in BundledAlertSound.allCases {
      let fromRecipe = AlertSoundRhythm(recipe: sound.recipe).taps
      let fromSamples = AlertSoundRhythm(
        samples: AlertSoundSynthesizer.render(sound.recipe),
        sampleRate: AlertSoundSynthesizer.sampleRate
      ).taps
      #expect(fromRecipe.count == fromSamples.count, "\(sound)")
      for (recipeTap, sampleTap) in zip(fromRecipe, fromSamples) {
        #expect(abs(recipeTap - sampleTap) <= 0.02, "\(sound)")
      }
    }
  }
}
