import AppKit
import CoreAudio
import CoreMediaIO
import Foundation

enum MeetingDetectionSettingsStore {
  private static let key = "meetingDetectionEnabled"

  static func load(from defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
  }

  static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: key)
  }
}

struct MeetingAppDetector {
  struct RunningApp: Equatable {
    let bundleIdentifier: String
    let isActive: Bool
  }

  /// A video meeting in progress, and how sure the evidence is.
  struct Detection: Equatable {
    let app: String
    /// Whether a camera is running. Without it the meeting was inferred from the
    /// microphone alone, which is enough to suggest recording but not to start one.
    let cameraActive: Bool
    /// Whether the app is known to be capturing audio itself, rather than merely
    /// running while something captures audio.
    let appIsUsingMicrophone: Bool
    /// A dedicated meeting app (Zoom, Teams…) rather than a browser.
    let isDedicatedApp: Bool
  }

  private static let dedicatedApps: [String: String] = [
    "us.zoom.xos": "Zoom",
    "us.zoom.ZoomPhone": "Zoom",
    "com.microsoft.teams2": "Teams",
    "com.microsoft.teams": "Teams",
    "com.apple.FaceTime": "FaceTime",
    "com.tinyspeck.slackmacgap": "Slack",
    "net.whatsapp.WhatsApp": "WhatsApp",
  ]

  /// Meeting apps capture audio from helper processes as well as their main one
  /// (for example `com.microsoft.teams2.helper`), so audio-capturing processes are
  /// matched by bundle prefix.
  private static let microphoneBundlePrefixes: [(prefix: String, app: String)] = [
    ("us.zoom.", "Zoom"),
    ("com.microsoft.teams", "Teams"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("net.whatsapp.WhatsApp", "WhatsApp"),
  ]

  private static let browserApps: [String: String] = [
    "com.google.Chrome": "Chrome",
    "com.apple.Safari": "Safari",
    "company.thebrowser.Browser": "Arc",
    "com.microsoft.edgemac": "Edge",
  ]

  /// The meeting app owning an audio-capturing process, if any.
  static func meetingApp(forMicrophoneBundle bundleIdentifier: String) -> String? {
    microphoneBundlePrefixes.first { bundleIdentifier.hasPrefix($0.prefix) }?.app
  }

  static func detectedApp(cameraActive: Bool, microphoneActive: Bool, apps: [RunningApp]) -> String? {
    detect(cameraActive: cameraActive, microphoneActive: microphoneActive, apps: apps,
           microphoneBundles: nil)?.app
  }

  /// - Parameter microphoneBundles: bundle identifiers of the processes capturing
  ///   audio, or nil where macOS cannot report them. When known, a dedicated app that
  ///   is capturing audio is a meeting even with the camera off.
  static func detect(
    cameraActive: Bool,
    microphoneActive: Bool,
    apps: [RunningApp],
    microphoneBundles: Set<String>?
  ) -> Detection? {
    guard microphoneActive else { return nil }
    let capturingApps = Set((microphoneBundles ?? []).compactMap(meetingApp(forMicrophoneBundle:)))

    // The app actually capturing audio is the strongest evidence, whatever is frontmost.
    if let app = capturingApps.sorted().first {
      return Detection(app: app, cameraActive: cameraActive, appIsUsingMicrophone: true,
                       isDedicatedApp: true)
    }

    guard cameraActive else { return nil }
    if let active = apps.first(where: { app in
      Self.dedicatedApps[app.bundleIdentifier] != nil && app.isActive
    }), let name = Self.dedicatedApps[active.bundleIdentifier] {
      return Detection(app: name, cameraActive: true, appIsUsingMicrophone: false, isDedicatedApp: true)
    }
    if let browser = apps.first(where: { app in
      Self.browserApps[app.bundleIdentifier] != nil && app.isActive
    }), let name = Self.browserApps[browser.bundleIdentifier] {
      return Detection(app: name, cameraActive: true, appIsUsingMicrophone: false, isDedicatedApp: false)
    }
    if let dedicated = apps.first(where: { Self.dedicatedApps[$0.bundleIdentifier] != nil }),
      let name = Self.dedicatedApps[dedicated.bundleIdentifier]
    {
      return Detection(app: name, cameraActive: true, appIsUsingMicrophone: false, isDedicatedApp: true)
    }
    return nil
  }
}

private typealias CameraListenerBlock = @convention(block) (
  UInt32, UnsafePointer<CMIOObjectPropertyAddress>?
) -> Void

@MainActor
final class MeetingActivityMonitor {
  var onDetectionChanged: ((MeetingAppDetector.Detection?) -> Void)?

  private var cameraListeners: [CMIOObjectID: CameraListenerBlock] = [:]
  private var cameraDeviceListListener: CameraListenerBlock?
  private var microphoneDeviceID: AudioDeviceID = 0
  private var microphoneListener: AudioObjectPropertyListenerBlock?
  private var defaultMicrophoneListener: AudioObjectPropertyListenerBlock?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var lastDetection: MeetingAppDetector.Detection?
  private var isStarted = false
  /// Re-evaluates while the microphone is in use: another process starting to capture
  /// from a microphone that is already running changes no device property to listen to.
  private var microphonePoll: Task<Void, Never>?
  private let microphoneProcesses = MicrophoneProcessQuery()
  static let microphonePollInterval: Duration = .seconds(3)

  /// Whether macOS reports which processes capture audio (macOS 14.2 and later).
  var canTellMicrophoneOwner: Bool { microphoneProcesses.isSupported }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    installCameraDeviceListListener()
    refreshCameraListeners()
    installMicrophoneListener()
    installDefaultMicrophoneListener()
    installWorkspaceObservers()
    evaluate()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    removeCameraListeners()
    removeCameraDeviceListListener()
    removeMicrophoneListener()
    removeDefaultMicrophoneListener()
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.forEach(center.removeObserver)
    workspaceObservers.removeAll()
    microphonePoll?.cancel()
    microphonePoll = nil
    publish(nil)
  }

  private func installWorkspaceObservers() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.evaluate() }
        })
    }
  }

  private func installCameraDeviceListListener() {
    let block: CameraListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refreshCameraListeners() }
    }
    cameraDeviceListListener = block
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    CMIOObjectAddPropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block)
  }

  private func removeCameraDeviceListListener() {
    guard let block = cameraDeviceListListener else { return }
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    CMIOObjectRemovePropertyListenerBlock(
      CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block)
    cameraDeviceListListener = nil
  }

  private func refreshCameraListeners() {
    let deviceIDs = Set(cameraDeviceIDs())
    for (deviceID, block) in cameraListeners where !deviceIDs.contains(deviceID) {
      removeCameraListener(deviceID: deviceID, block: block)
      cameraListeners.removeValue(forKey: deviceID)
    }
    for deviceID in deviceIDs where cameraListeners[deviceID] == nil {
      let block: CameraListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.evaluate() }
      }
      cameraListeners[deviceID] = block
      var address = cameraRunningAddress
      CMIOObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
    }
    evaluate()
  }

  private func removeCameraListeners() {
    for (deviceID, block) in cameraListeners {
      removeCameraListener(deviceID: deviceID, block: block)
    }
    cameraListeners.removeAll()
  }

  private func removeCameraListener(deviceID: CMIOObjectID, block: @escaping CameraListenerBlock) {
    var address = cameraRunningAddress
    CMIOObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
  }

  private var cameraRunningAddress: CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
  }

  private func cameraDeviceIDs() -> [CMIOObjectID] {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(
      CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
      dataSize > 0
    else { return [] }
    var devices = [CMIOObjectID](
      repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
    var used = dataSize
    guard CMIOObjectGetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &devices) == noErr
    else { return [] }
    return devices
  }

  private func isCameraActive() -> Bool {
    cameraListeners.keys.contains { deviceID in
      var address = cameraRunningAddress
      var running: UInt32 = 0
      var used = UInt32(MemoryLayout<UInt32>.size)
      return CMIOObjectGetPropertyData(
        deviceID, &address, 0, nil, used, &used, &running) == noErr && running != 0
    }
  }

  private func installMicrophoneListener() {
    removeMicrophoneListener()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0
    else { return }
    microphoneDeviceID = deviceID
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.evaluate() }
    }
    microphoneListener = block
    var runningAddress = microphoneRunningAddress
    AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
  }

  private func removeMicrophoneListener() {
    guard microphoneDeviceID != 0, let block = microphoneListener else { return }
    var address = microphoneRunningAddress
    AudioObjectRemovePropertyListenerBlock(microphoneDeviceID, &address, nil, block)
    microphoneDeviceID = 0
    microphoneListener = nil
  }

  private func installDefaultMicrophoneListener() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.installMicrophoneListener()
        self?.evaluate()
      }
    }
    defaultMicrophoneListener = block
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
  }

  private func removeDefaultMicrophoneListener() {
    guard let block = defaultMicrophoneListener else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    defaultMicrophoneListener = nil
  }

  private var microphoneRunningAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private func isMicrophoneActive() -> Bool {
    guard microphoneDeviceID != 0 else { return false }
    var address = microphoneRunningAddress
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(
      microphoneDeviceID, &address, 0, nil, &size, &running) == noErr && running != 0
  }

  private func evaluate() {
    guard isStarted else { return }
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingAppDetector.RunningApp? in
      guard let bundleIdentifier = app.bundleIdentifier else { return nil }
      return .init(bundleIdentifier: bundleIdentifier, isActive: app.isActive)
    }
    let microphoneActive = isMicrophoneActive()
    updateMicrophonePoll(microphoneActive: microphoneActive)
    publish(MeetingAppDetector.detect(
      cameraActive: isCameraActive(), microphoneActive: microphoneActive, apps: apps,
      microphoneBundles: microphoneActive ? microphoneProcesses.capturingBundleIdentifiers() : nil))
  }

  private func updateMicrophonePoll(microphoneActive: Bool) {
    guard microphoneActive else {
      microphonePoll?.cancel()
      microphonePoll = nil
      return
    }
    guard microphonePoll == nil, microphoneProcesses.isSupported else { return }
    microphonePoll = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.microphonePollInterval)
        guard !Task.isCancelled else { return }
        self?.evaluate()
      }
    }
  }

  private func publish(_ detection: MeetingAppDetector.Detection?) {
    guard detection != lastDetection else { return }
    lastDetection = detection
    onDetectionChanged?(detection)
  }
}

/// Which processes are capturing audio, from Core Audio's process objects
/// (macOS 14.2 and later). Reading them needs no permission.
@MainActor
final class MicrophoneProcessQuery {
  private var supported: Bool?

  /// False once macOS has reported that process objects are unavailable.
  var isSupported: Bool { supported != false }

  /// Bundle identifiers of the processes running audio input, or nil when macOS
  /// cannot tell.
  func capturingBundleIdentifiers() -> Set<String>? {
    guard let processes = processObjects() else { return nil }
    var bundles = Set<String>()
    for process in processes where isRunningInput(process) {
      if let bundle = bundleIdentifier(of: process), !bundle.isEmpty { bundles.insert(bundle) }
    }
    return bundles
  }

  private func processObjects() -> [AudioObjectID]? {
    guard supported != false else { return nil }
    var address = Self.address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else {
      supported = false
      return nil
    }
    supported = true
    guard size > 0 else { return [] }
    var processes = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr
    else { return nil }
    return processes
  }

  private func isRunningInput(_ process: AudioObjectID) -> Bool {
    var address = Self.address(kAudioProcessPropertyIsRunningInput)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
  }

  private func bundleIdentifier(of process: AudioObjectID) -> String? {
    var address = Self.address(kAudioProcessPropertyBundleID)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}
