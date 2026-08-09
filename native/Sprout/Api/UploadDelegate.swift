import Foundation

/// Runs one `uploadTask(fromFile:)` and reports byte progress.
///
/// `URLSession.upload(for:fromFile:)` exists but gives no progress, and the upload sheet's progress
/// bar is load-bearing for multi-megabyte 3MFs — so this drives the task through a delegate instead.
/// One session per upload keeps the delegate's state trivially isolated; uploads are rare and
/// user-initiated, so the session churn costs nothing.
final class UploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private var received = Data()
    private let onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<(Data, URLResponse?), Error>?
    private var response: URLResponse?

    private init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    static func perform(
        request: URLRequest,
        fromFile: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse?) {
        let delegate = UploadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.uploadTask(with: request, fromFile: fromFile).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        self.response = response
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: (received, response ?? task.response))
        }
    }
}
