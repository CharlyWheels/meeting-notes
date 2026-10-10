import Foundation

/// Which meeting apps start recording on their own, without the notification.
/// Off for every app by default.
enum AutoRecordSettingsStore {
  private static let key = "autoRecordMeetingApps"
  /// Dedicated apps only: a browser with the camera on is too often not a meeting.
  static let supportedApps = ["Teams", "Zoom"]

  static func load(from defaults: UserDefaults = .standard) -> Set<String> {
    Set((defaults.array(forKey: key) as? [String] ?? []).filter(supportedApps.contains))
  }

  static func save(_ apps: Set<String>, to defaults: UserDefaults = .standard) {
    defaults.set(apps.filter(supportedApps.contains).sorted(), forKey: key)
  }
}

enum AutoRecordPolicy {
  /// A recording that started on its own stops this long after the meeting app
  /// releases the microphone, so muting or switching headsets does not end it.
  static let gracePeriod: Duration = .seconds(60)

  /// Records without asking only on the strongest evidence: the camera is on and an
  /// enabled dedicated app is in the meeting. Where macOS reports which process is
  /// capturing audio, that app must be the one using the microphone, so a camera
  /// test in another app while Teams sits in the background does not start a recording.
  static func shouldStart(
    _ detection: MeetingAppDetector.Detection,
    enabledApps: Set<String>,
    canTellMicrophoneOwner: Bool
  ) -> Bool {
    guard detection.cameraActive, detection.isDedicatedApp,
      enabledApps.contains(detection.app)
    else { return false }
    return detection.appIsUsingMicrophone || !canTellMicrophoneOwner
  }
}
