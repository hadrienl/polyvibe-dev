import Foundation

/// The rhythm the trackpad plays with the alert sound (#555): one tap at each attack of the sound,
/// in seconds from its start. Drawn from the sound itself — its recipe when it has one, its samples
/// otherwise — so that a sound and its rhythm never disagree.
public struct AlertSoundRhythm: Hashable, Sendable {
  /// When each tap falls, in seconds from the start of the sound, in order.
  public let taps: [Double]

  /// What a sound of 30 seconds can hold without becoming a buzz.
  public static let maximumTaps = 24
  /// Two attacks closer than this are felt as one: a chord, or a note and its click.
  public static let mergeInterval = 0.09
  /// A sound without a clear attack — a hum, a sweep — or one that could not be read.
  public static let single = AlertSoundRhythm(taps: [0])

  /// `taps` in order, those closer than `minimumGap` to the one before dropped, `maximumTaps` at
  /// most; never empty — a sound always gives its first tap.
  public init(taps: [Double], minimumGap: Double = mergeInterval) {
    var kept: [Double] = []
    for tap in taps.filter({ $0.isFinite && $0 >= 0 }).sorted() {
      if let last = kept.last, tap - last < minimumGap { continue }
      kept.append(tap)
      if kept.count == Self.maximumTaps { break }
    }
    self.taps = kept.isEmpty ? [0] : kept
  }

  /// The same rhythm, with no two taps closer than `gap`: what a trackpad that loses the taps too
  /// close together still plays.
  public func spaced(by gap: Double) -> AlertSoundRhythm {
    AlertSoundRhythm(taps: taps, minimumGap: gap)
  }

  // MARK: - From a recipe

  /// A tap at the start of every note of a voice that is heard. The echo adds none: it repeats
  /// what was felt already.
  public init(recipe: AlertSoundRecipe) {
    self.init(
      taps: recipe.voices.filter { $0.gain > 0 }.flatMap { $0.notes.map(\.start) })
  }

  // MARK: - From samples

  /// How the attacks of a sound are found: its loudness over short windows, and a tap wherever it
  /// rises clearly above what came just before.
  enum Attack {
    /// The loudness is read over windows long enough to hold a period of the lowest tone a
    /// recipe plays (25 Hz is 40 ms; 20 ms holds the 50 Hz most sounds stay above), every 10 ms.
    static let window = 0.02
    static let hop = 0.01
    /// What came just before: the quietest window of the last 60 ms.
    static let memory = 6
    /// An attack is at least this loud, the loudest window being 1…
    static let threshold: Float = 0.12
    /// …and this many times what came just before.
    static let rise: Float = 1.8
  }

  /// A tap at each attack of `samples`, mono, at `sampleRate`.
  public init(samples: [Float], sampleRate: Int) {
    let levels = Self.levels(of: samples, sampleRate: sampleRate)
    var taps: [Double] = []
    for (index, level) in levels.enumerated() where level >= Attack.threshold {
      let before = levels[max(0, index - Attack.memory)..<index]
      let floor = before.min() ?? 0
      let rising = index == 0 || level > levels[index - 1]
      if rising, level >= floor * Attack.rise + Attack.threshold / 2 {
        taps.append(Double(index) * Attack.hop)
      }
    }
    self.init(taps: taps)
  }

  /// The loudness of each window, from 0 to 1 (the loudest).
  static func levels(of samples: [Float], sampleRate: Int) -> [Float] {
    guard sampleRate > 0, !samples.isEmpty else { return [] }
    let window = max(1, Int(Attack.window * Double(sampleRate)))
    let hop = max(1, Int(Attack.hop * Double(sampleRate)))
    var levels: [Float] = []
    var start = 0
    while start < samples.count {
      var peak: Float = 0
      for index in start..<min(start + window, samples.count) {
        peak = max(peak, abs(samples[index]))
      }
      levels.append(peak)
      start += hop
    }
    let loudest = levels.max() ?? 0
    guard loudest > .ulpOfOne else { return [] }
    return levels.map { $0 / loudest }
  }
}
