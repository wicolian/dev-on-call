import AppKit
import DevOnCallCore
import Foundation
import UserNotifications

@MainActor
final class AlertOutputService {
    private var currentSound: NSSound?
    private let speech = NSSpeechSynthesizer()

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func postNotification(for event: AlertEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.subtitle = event.source
        content.body = event.detail
        content.sound = nil
        let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func playSound(customPath: String) {
        currentSound?.stop()
        let expanded = NSString(string: customPath).expandingTildeInPath
        if !expanded.isEmpty,
           let sound = NSSound(contentsOfFile: expanded, byReference: true) {
            currentSound = sound
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    func speak(_ message: String) {
        speech.stopSpeaking()
        speech.startSpeaking(message)
    }

    func stop() {
        currentSound?.stop()
        speech.stopSpeaking()
    }
}
