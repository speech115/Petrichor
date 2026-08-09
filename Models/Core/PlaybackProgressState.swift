import Foundation

class PlaybackProgressState: ObservableObject {
    @Published var currentTime: Double = 0

    /// Seconds between `currentTime` refreshes. Progress bars tween across
    /// exactly this long, so the playhead reads as continuous instead of
    /// stepping once per sample. Published because the sampler switches rate
    /// while a lyrics view is open.
    @Published var sampleInterval: Double = 1
}
