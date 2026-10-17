import AVFoundation
import Foundation

/// Copies each reader output into its writer input, each on its own queue, until every one is done,
/// one fails, or `isCancelled` says so: the mixdown's copy (`ScreencastAudioMixdown`) and the export
/// of edits' (`ScreencastEditExporter`), after Snapzy's and Shotnix's copy loops (see each).
///
/// A failure or a cancel stops every queue at its next sample, and only once none is inside the
/// reader or the writer are both cancelled: cancelling a writer while another queue appends to it
/// crashes. A cancelled writer never asks a waiting input for more, so the copy ends without it.
final class ScreencastSampleCopier: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)]
    private let label: String
    private let qos: DispatchQoS
    private let isCancelled: @Sendable () -> Bool
    private let group = DispatchGroup()
    private let lock = NSLock()
    /// Each input whose output is done, or that the stop released: each leaves the group once.
    private var finished: [Bool]
    /// A queue failed or saw the cancel: no queue copies another sample.
    private var stopping = false
    /// The reader and writer are cancelled.
    private var stopped = false
    /// Queues inside a copy, which the stop waits for.
    private var copying = 0

    private enum Outcome {
        /// The input isn't ready: its queue is asked again once it is.
        case waiting
        /// The output had no more.
        case finished
        /// An append failed, or the cancel was seen.
        case stop
    }

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)],
        label: String,
        qos: DispatchQoS,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.reader = reader
        self.writer = writer
        self.pairs = pairs
        self.label = label
        self.qos = qos
        self.isCancelled = isCancelled
        finished = Array(repeating: false, count: pairs.count)
    }

    /// Whether it stopped, for a failure or the cancel, before every output was done.
    var didStop: Bool { lock.withLock { stopping } }

    /// Copies, once the reader and writer have started, passing each sample to `onSample` with its
    /// pair's index first, and calls `completion` once every input is done or the copy stopped.
    func run(
        onSample: @escaping @Sendable (Int, CMSampleBuffer) -> Void = { _, _ in },
        completion: @escaping @Sendable () -> Void
    ) {
        for (index, pair) in pairs.enumerated() {
            group.enter()
            let queue = DispatchQueue(label: "\(label).\(index)", qos: qos)
            pair.input.requestMediaDataWhenReady(on: queue) { [self] in
                copy(index, onSample: onSample)
            }
        }
        group.notify(queue: .global(qos: qos.qosClass), execute: completion)
    }

    /// Appends what the input will take, in an autorelease pool per sample, as Shotnix's
    /// `MovieJob` does: without one, every decoded frame stays alive until the queue pauses.
    private func copy(_ index: Int, onSample: (Int, CMSampleBuffer) -> Void) {
        let enters = lock.withLock {
            guard !stopping, !finished[index] else { return false }
            copying += 1
            return true
        }
        guard enters else { return }
        var outcome = Outcome.waiting
        defer { leave(index, outcome) }
        let (output, input) = pairs[index]
        while input.isReadyForMoreMediaData {
            guard !lock.withLock({ stopping }) else { return }
            guard !isCancelled() else {
                outcome = .stop
                return
            }
            let appended = autoreleasepool { () -> Bool? in
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                onSample(index, sample)
                // Appending to a writer that failed on its own raises an exception.
                return writer.status == .writing && input.append(sample)
            }
            switch appended {
            case nil:
                if writer.status == .writing { input.markAsFinished() }
                outcome = .finished
                return
            case false?:
                outcome = .stop
                return
            case true?:
                continue
            }
        }
    }

    /// A queue is out of its copy. The last one out after a stop cancels the reader and writer,
    /// and releases every input still waiting.
    private func leave(_ index: Int, _ outcome: Outcome) {
        var leaves = 0
        let halts = lock.withLock {
            copying -= 1
            if outcome == .finished, !finished[index] {
                finished[index] = true
                leaves += 1
            }
            if outcome == .stop { stopping = true }
            guard stopping, copying == 0, !stopped else { return false }
            stopped = true
            return true
        }
        if halts {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            leaves += lock.withLock {
                let waiting = finished.indices.filter { !finished[$0] }
                waiting.forEach { finished[$0] = true }
                return waiting.count
            }
        }
        for _ in 0..<leaves { group.leave() }
    }
}
