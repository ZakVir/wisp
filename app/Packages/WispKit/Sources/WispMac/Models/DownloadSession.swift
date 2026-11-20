import Foundation
import os
import WispCore

/// A download that failed; carries resume data when the server supports resuming.
public struct DownloadError: Error, Sendable {
    public var failure: ModelFailure
    public var resumeData: Data?
}

/// Thin async wrapper over a delegate-based `URLSession` download session.
///
/// With a background configuration (the app's default), transfers continue in the system daemon while
/// Wisp is not running; on the next launch, recreating the session with the same identifier re-delivers
/// finished files and lets `fetch` re-attach to in-flight tasks by key instead of starting over.
public final class DownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Waiter {
        var continuation: CheckedContinuation<URL, Error>
        var progress: @Sendable (Int64, Int64) -> Void
    }

    private let lock = NSLock()
    private var waiters: [String: Waiter] = [:]
    /// Files that finished while nobody was waiting (e.g. completed while Wisp was closed).
    private var finished: [String: URL] = [:]
    private var failedEarly: [String: DownloadError] = [:]
    private let holdingDirectory: URL
    private var session: URLSession!

    /// - Parameters:
    ///   - configuration: `.background(withIdentifier:)` in the app, `.ephemeral` in tests.
    ///   - holdingDirectory: where finished temp files are moved (the system deletes its own temp file
    ///     as soon as the delegate callback returns).
    public init(configuration: URLSessionConfiguration, holdingDirectory: URL) {
        self.holdingDirectory = holdingDirectory
        super.init()
        // In-process session: nothing from a previous run is still referenced, so start with an empty folder.
        try? FileManager.default.removeItem(at: holdingDirectory)
        try? FileManager.default.createDirectory(at: holdingDirectory, withIntermediateDirectories: true)
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Downloads `url` (or re-attaches to a transfer already running/finished under `key`) and returns the
    /// downloaded file's location in the holding directory. The caller verifies and moves it.
    public func fetch(_ url: URL, key: String, resumeData: Data?,
                      progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        if let done = takeFinished(key) { return done }
        if let early = takeFailedEarly(key) { throw early }
        let tasks = await session.allTasks
        let existing = tasks.first { $0.taskDescription == key && $0.state == .running } as? URLSessionDownloadTask
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                // Register, unless the transfer finished in the gap since we last looked (then resume now).
                let raced: Result<URL, DownloadError>? = lock.withLock {
                    if let url = finished.removeValue(forKey: key) { return .success(url) }
                    if let error = failedEarly.removeValue(forKey: key) { return .failure(error) }
                    // A second fetch for the same key replaces the first; end the first one instead of losing it.
                    if let old = waiters[key] {
                        old.continuation.resume(throwing: DownloadError(failure: .interrupted, resumeData: nil))
                    }
                    waiters[key] = Waiter(continuation: continuation, progress: progress)
                    return nil
                }
                if let raced {
                    switch raced {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                    return
                }
                if existing != nil { return } // re-attached; delegate callbacks will resume us
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                task.taskDescription = key
                task.resume()
            }
        } onCancel: {
            Task { [weak self] in
                guard let self else { return }
                for task in await self.session.allTasks where task.taskDescription == key {
                    (task as? URLSessionDownloadTask)?.cancel(byProducingResumeData: { _ in })
                }
            }
        }
    }

    /// Cancels everything (Remove models).
    public func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        let orphans = lock.withLock { () -> [URL] in
            let urls = Array(finished.values)
            finished.removeAll()
            failedEarly.removeAll()
            return urls
        }
        orphans.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Stops every running download and returns resume data by key (call when the app quits, so the next
    /// launch continues where it left off). Waits at most `timeout` seconds.
    public func suspendAllProducingResumeData(timeout: TimeInterval = 2) -> [String: Data] {
        let group = DispatchGroup()
        let collected = OSAllocatedUnfairLock(initialState: [String: Data]())
        group.enter()
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks where task.state == .running {
                guard let key = task.taskDescription else { continue }
                group.enter()
                task.cancel(byProducingResumeData: { data in
                    if let data { collected.withLock { $0[key] = data } }
                    group.leave()
                })
            }
            group.leave()
        }
        _ = group.wait(timeout: .now() + timeout)
        return collected.withLock { $0 }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let waiter = lock.withLock { waiters[key] }
        waiter?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            deliver(key, .failure(DownloadError(failure: ModelFailure.classify(httpStatus: http.statusCode), resumeData: nil)))
            return
        }
        // Must move synchronously: the system deletes `location` when this method returns.
        let target = holdingDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            deliver(key, .success(target))
        } catch {
            deliver(key, .failure(DownloadError(failure: ModelFailure.classify(error), resumeData: nil)))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        deliver(key, .failure(DownloadError(failure: ModelFailure.classify(error), resumeData: resume)))
    }

    // MARK: Bookkeeping

    private func deliver(_ key: String, _ result: Result<URL, DownloadError>) {
        let waiter: Waiter? = lock.withLock {
            let w = waiters.removeValue(forKey: key)
            if w == nil {
                switch result {
                case .success(let url): finished[key] = url
                case .failure(let error): failedEarly[key] = error
                }
            }
            return w
        }
        guard let waiter else { return }
        switch result {
        case .success(let url): waiter.continuation.resume(returning: url)
        case .failure(let error): waiter.continuation.resume(throwing: error)
        }
    }

    private func takeFinished(_ key: String) -> URL? {
        lock.withLock { finished.removeValue(forKey: key) }
    }

    private func takeFailedEarly(_ key: String) -> DownloadError? {
        lock.withLock { failedEarly.removeValue(forKey: key) }
    }
}
