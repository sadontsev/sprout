import UIKit
import UserNotifications

/// Puts a picture of the printer on a halt banner.
///
/// A notification's content can be rewritten before display by exactly one API — this one, launched
/// by iOS when a push carries `mutable-content: 1`. That is the whole reason this target exists: the
/// alert body is composed by the server, and an image has to come from somewhere the server cannot
/// reach.
///
/// **What it is a picture OF.** A live camera grab, taken when the push is DELIVERED. Not when the
/// fault happened: a phone that was offline for an hour photographs the printer an hour later. That
/// is worth knowing before reading anything into the frame.
///
/// **Every failure looks the same from the phone** — the banner arrives with its text and no
/// picture. Not onboarded, no app group, the camera off (Bambuddy answers 503), a token that has
/// expired, the phone offline, or the work overrunning whatever time iOS gives this process. That is
/// deliberate: a notification that failed to decorate itself must still deliver its sentence, which
/// is the part that matters. It also means a missing picture cannot be diagnosed from the handset,
/// only from the server's log.
final class NotificationService: UNNotificationServiceExtension {

    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.handler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        self.content = mutable

        guard let mutable else {
            contentHandler(request.content)
            return
        }

        let userInfo = request.content.userInfo
        guard let token = ShotHandoff.token(in: userInfo),
              let printerId = ShotHandoff.printerId(in: userInfo),
              let base = SecureConfig.sharedBaseUrl(),
              let url = ShotHandoff.url(base: base, printerId: printerId, token: token)
        else {
            // Nothing to fetch, or nothing to fetch it from. Deliver the banner as it came rather
            // than holding it while we work out that there was never a picture to add.
            contentHandler(mutable)
            return
        }

        var urlRequest = URLRequest(url: url)
        // Shorter than whatever iOS allows, on purpose: `serviceExtensionTimeWillExpire` is a last
        // chance to submit, not a chance to finish, and a request still in flight when it fires
        // delivers nothing. Apple documents no specific budget, so this does not pretend to know
        // one — it just makes sure the request gives up before the process is asked to.
        urlRequest.timeoutInterval = 12

        URLSession(configuration: .ephemeral).dataTask(with: urlRequest) { [weak self] data, response, _ in
            guard let self else { return }
            defer { self.finish() }
            guard let data, !data.isEmpty,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  // A 200 is not enough: an error page is also a 200 somewhere, and a body that is
                  // not an image makes `UNNotificationAttachment` throw rather than fail quietly.
                  UIImage(data: data) != nil
            else { return }
            self.attach(data)
        }.resume()
    }

    /// The system's last call before the process is taken away.
    ///
    /// Whatever is on `content` is what ships. If the fetch has not landed, that is the original
    /// text with no picture — which is exactly the right outcome and the reason the body is never
    /// held back waiting for an image.
    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func attach(_ data: Data) {
        // A file, because that is the only thing `UNNotificationAttachment` takes. The extension
        // gets its own container and iOS moves the file into the notification's own storage, so the
        // temporary directory is the right place and cleaning up is not this code's job.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shot-\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil,
              let attachment = try? UNNotificationAttachment(identifier: "shot", url: url, options: nil)
        else { return }
        content?.attachments = [attachment]
    }

    /// Deliver once, whichever path gets here first — the fetch completing or the system running out
    /// of patience. Both can happen, and calling the handler twice is a crash.
    private func finish() {
        guard let handler, let content else { return }
        self.handler = nil
        handler(content)
    }
}
