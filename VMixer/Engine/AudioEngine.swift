//
//  AudioEngine.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine
import Accelerate
import AVFoundation
import os

@MainActor
final class AudioEngine: ObservableObject {
    
    // Uses os_unfair_lock to prevent priority inversion audio dropouts
    private final class RealtimeControl {
        private var lock = os_unfair_lock_s()
        private var _volume: Float = 1.0
        private var _muted = false
        private var _lastFrameCount: UInt64 = 0
        private var _currentLevel: Float = 0.0
        
        // NEW: Automatically boosts quiet mixdown taps back to 100%
        let volumeCompensation: Float
        
        init(volumeCompensation: Float = 1.0) {
            self.volumeCompensation = volumeCompensation
        }
        
        var gain: Float {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _muted ? 0.0 : (_volume * volumeCompensation)
        }
        
        var currentLevel: Float {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _currentLevel
        }
        
        func set(volume: Float) {
            os_unfair_lock_lock(&lock)
            _volume = min(max(volume, 0.0), 1.0)
            os_unfair_lock_unlock(&lock)
        }
        
        func set(muted: Bool) {
            os_unfair_lock_lock(&lock)
            _muted = muted
            os_unfair_lock_unlock(&lock)
        }
        
        func set(level: Float) {
            os_unfair_lock_lock(&lock)
            _currentLevel = level
            os_unfair_lock_unlock(&lock)
        }
        
        func add(frames: UInt32) {
            os_unfair_lock_lock(&lock)
            _lastFrameCount &+= UInt64(frames)
            os_unfair_lock_unlock(&lock)
        }
    }

    struct Target: Identifiable {
        let id: Int32
        let pid: Int32
        var displayName: String
        var tapID: AudioObjectID
        var aggregateDeviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID?
        var volume: Float
        var isMuted: Bool
        var level: Float = 0.0
        var icon: NSImage?
    }

    struct RunningApp: Identifiable, Hashable {
        let pid: Int32
        let name: String
        let bundleID: String?

        var id: Int32 { pid }
        var title: String {
            if let bundleID, !bundleID.isEmpty { return "\(name) (\(bundleID))" }
            return name
        }
    }

    @Published private(set) var targets: [Target] = []
    @Published private(set) var runningApps: [RunningApp] = []
    @Published var statusMessage = "Ready"
    
    private var controlsByPID: [Int32: RealtimeControl] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var meterTimer: Timer?
    
    // MARK: - Linked Master Volume Controls
    private var isSyncingInternally = false
    private var preMuteVolume: Float = 0.5
    private var currentListeningDeviceID: AudioObjectID = 0
    
    @Published var masterVolume: Float = 1.0 {
        didSet {
            guard !isSyncingInternally else { return }
            isSyncingInternally = true
            syncSystemVolume(to: masterVolume)
            
            if masterVolume <= 0.001 && !isMasterMuted {
                isMasterMuted = true
            } else if masterVolume > 0.001 && isMasterMuted {
                isMasterMuted = false
            }
            isSyncingInternally = false
        }
    }
    
    @Published var isMasterMuted: Bool = false {
        didSet {
            guard !isSyncingInternally else { return }
            isSyncingInternally = true
            syncSystemMute(muted: isMasterMuted)
            
            if isMasterMuted {
                if masterVolume > 0.001 { preMuteVolume = masterVolume }
                masterVolume = 0.0
                syncSystemVolume(to: 0.0)
            } else {
                if masterVolume <= 0.001 {
                    masterVolume = preMuteVolume > 0.001 ? preMuteVolume : 0.5
                    syncSystemVolume(to: masterVolume)
                }
            }
            isSyncingInternally = false
        }
    }
    
    struct AudioDevice: Identifiable, Hashable {
        let id: UInt32
        let name: String
    }
    
    @Published var outputDevices: [AudioDevice] = [
        AudioDevice(id: 0, name: "System Default")
    ]
    
    @Published var selectedOutputDeviceID: UInt32 = 0 {
        didSet {
            if selectedOutputDeviceID != 0 && selectedOutputDeviceID != oldValue {
                setDefaultOutputDevice(deviceID: selectedOutputDeviceID)
            }
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [
            "autoHookEnabled": true,
            "ignoredBundleIDs": "com.apple.finder"
        ])
        
        cleanupOrphanedDevices()
        
        refreshRunningApps()
        
        self.isSyncingInternally = true
        self.masterVolume = getCurrentSystemVolume()
        self.isMasterMuted = getCurrentSystemMute()
        self.isSyncingInternally = false
        
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        
        fetchOutputDevices()
        setupSystemAudioListeners()
        
        autoHookExistingMediaApps()
        setupAutoHookingObserver()
        
        let timer = Timer(timeInterval: 1.0/30, repeats: true) { [weak self] _ in
            Task{@MainActor[weak self] in
                self?.updateMeters()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
        
    }
    
    private func updateMeters() {
        for i in 0..<targets.count {
            let pid = targets[i].pid
            if let control = controlsByPID[pid] { targets[i].level = control.currentLevel }
        }
    }
    
    // MARK: - Orphan Cleanup
    private func cleanupOrphanedDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs) == noErr
        else { return }
        
        for deviceID in deviceIDs {
            if let name = getDeviceName(deviceID: deviceID), name.hasPrefix("VMixer-") {
                print("Destroying orphaned aggregate device: \(name)")
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Auto Hooking Logic
    private func autoHookExistingMediaApps() {
        guard UserDefaults.standard.bool(forKey: "autoHookEnabled") else { return }
        
        let ignoredString = UserDefaults.standard.string(forKey: "ignoredBundleIDs") ?? "com.apple.finder"
        let ignoredBundleIDs = Set(ignoredString.split(separator: ",").map(String.init))
        
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 100,
                  let bundleID = app.bundleIdentifier,
                  !ignoredBundleIDs.contains(bundleID),
                  app.processIdentifier > 0 else { continue }

            let runningApp = RunningApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID,
                bundleID: bundleID
            )
            addTarget(app: runningApp)
        }
    }

    private func setupAutoHookingObserver() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                
                guard UserDefaults.standard.bool(forKey: "autoHookEnabled") else { return }
                
                let ignoredString = UserDefaults.standard.string(forKey: "ignoredBundleIDs") ?? "com.apple.finder"
                let ignoredBundleIDs = Set(ignoredString.split(separator: ",").map(String.init))
                
                if let bundleID = app.bundleIdentifier, ignoredBundleIDs.contains(bundleID) { return }
                if self.targets.contains(where: { $0.pid == app.processIdentifier }) { return }
                
                let runningApp = RunningApp(pid: app.processIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "Unknown", bundleID: app.bundleIdentifier)
                self.addTarget(app: runningApp)
            }
            .store(in: &cancellables)
        
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.removeTarget(pid: app.processIdentifier)
            }
            .store(in: &cancellables)
    }

    // MARK: - App Tracking & Setup
    func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 && !$0.isTerminated }
            .compactMap { app -> RunningApp? in
                let pid = Int32(app.processIdentifier)
                guard pid > 0, pid != Int32(ProcessInfo.processInfo.processIdentifier) else { return nil }
                let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? app.bundleIdentifier ?? "PID \(pid)"
                return RunningApp(pid: pid, name: name, bundleID: app.bundleIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        runningApps = apps
    }

    func addTarget(pid: Int32, name: String?) {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        addTarget(pid: pid, name: name, bundleID: bundleID)
    }

    @discardableResult
    private func addTarget(pid: Int32, name: String?, bundleID: String?) -> Bool {
        guard pid > 0, !targets.contains(where: { $0.pid == pid }) else { return false }

        guard let tapResult = createTapWithFallback(pid: pid, bundleID: bundleID) else { return false }
        let tapID = tapResult.tapID
        guard tapID != kAudioObjectUnknown, tapID != 0 else { return false }

        let control = RealtimeControl(volumeCompensation: tapResult.volumeCompensation)
        
        guard let aggregateDeviceID = createAggregateDevice(tapID: tapID) else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        guard let ioProcID = startTapIO(deviceID: aggregateDeviceID, control: control) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            return false
        }

        controlsByPID[pid] = control
        let displayName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PID \(pid)" : name!
        let appIcon = NSRunningApplication(processIdentifier: pid)?.icon

        let target = Target(
            id: pid,
            pid: pid,
            displayName: displayName,
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            ioProcID: ioProcID,
            volume: 1.0,
            isMuted: false,
            icon: appIcon
        )
        targets.append(target)
        statusMessage = "Auto-Hooked \(target.displayName)"
        return true
    }

    func addTarget(app: RunningApp) {
        guard !targets.contains(where: { $0.pid == app.pid }) else { return }
        
        if !addTarget(pid: app.pid, name: app.name, bundleID: app.bundleID) {
            print("Initial tap creation failed for \(app.name). Queueing retry...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retryTapCreation(for: app)
            }
        }
    }

    private func retryTapCreation(for app: RunningApp) {
        guard !targets.contains(where: { $0.pid == app.pid }) else { return }
        if addTarget(pid: app.pid, name: app.name, bundleID: app.bundleID) {
            print("Successfully hooked \(app.name) on retry.")
        }
    }

    // MARK: - CoreAudio Integration
    private func createTapWithFallback(pid: Int32, bundleID: String?) -> (tapID: AudioObjectID, volumeCompensation: Float)? {
        
        if let bundleID, !bundleID.isEmpty {
            var bundleTapID: AudioObjectID = 0
            let bundleDescription = CATapDescription()
            bundleDescription.uuid = UUID()
            
            var bundlesToTap = [bundleID]
            var compensation: Float = 1.0
            switch bundleID {
            case "com.spotify.client":
                bundlesToTap.append("com.spotify.client.helper")
                compensation = 1.0
            case "com.apple.Music":
                bundlesToTap.append("com.apple.audio.sandbox")
                compensation = 1.0
            case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
                bundlesToTap.append("com.apple.WebKit.WebContent")
                bundlesToTap.append("com.apple.WebKit.GPU")
                compensation = 1.25
                
            case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
                bundlesToTap.append("\(bundleID).helper")
                bundlesToTap.append("\(bundleID).helper.renderer")
                bundlesToTap.append("\(bundleID).helper.plugin")
                compensation = 2.0
                
            case "org.mozilla.firefox":
                bundlesToTap.append("org.mozilla.plugincontainer")
                compensation = 2.0
                
            case "com.apple.FaceTime":
                bundlesToTap = ["com.apple.avconferenced"]
                bundlesToTap.append("com.apple.telephonyutilities.callservicesd")
                compensation = 3.0
                
            default: break
            }
            
           
            let needsMixdown = bundlesToTap.count > 1
            
            bundleDescription.bundleIDs = bundlesToTap
            bundleDescription.isMixdown = needsMixdown
            bundleDescription.isMono = false
            bundleDescription.name = "VMixerTap-\(pid)"
            bundleDescription.isPrivate = false
            bundleDescription.muteBehavior = .mutedWhenTapped

            let status = AudioHardwareCreateProcessTap(bundleDescription, &bundleTapID)
            if status == noErr {
                let recoveredTapID = normalizedTapID(bundleTapID, fallbackUID: bundleDescription.uuid.uuidString, expectedName: bundleDescription.name)
                if recoveredTapID != kAudioObjectUnknown, recoveredTapID != 0 {
                    return (recoveredTapID, needsMixdown ? compensation : 1.0)
                }
                statusMessage = "Tap created but UID lookup failed for \(bundleID)"
                return nil
            } else {
                print("AudioHardwareCreateProcessTap failed for \(bundleID) with OSStatus: \(status)")
            }
        }

        if let processObjectID = translatePIDToProcessObjectID(pid: pid) {
            var pidTapID: AudioObjectID = 0
            let pidDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
            pidDescription.uuid = UUID()
            pidDescription.name = "VMixerTap-\(pid)"
            pidDescription.isPrivate = false
            pidDescription.muteBehavior = .mutedWhenTapped

            let status = AudioHardwareCreateProcessTap(pidDescription, &pidTapID)
            if status == noErr {
                let recoveredTapID = normalizedTapID(pidTapID, fallbackUID: pidDescription.uuid.uuidString, expectedName: pidDescription.name)
                if recoveredTapID != kAudioObjectUnknown, recoveredTapID != 0 {
                    return (recoveredTapID, 2.0)
                }
                return nil
            } else {
                print("AudioHardwareCreateProcessTap by PID failed for \(pid) with OSStatus: \(status)")
            }
        }

        statusMessage = "PID \(pid) cannot be tapped."
        return nil
    }

    private func normalizedTapID(_ tapID: AudioObjectID, fallbackUID: String, expectedName: String) -> AudioObjectID {
        if tapID != 0, tapID != kAudioObjectUnknown { return tapID }
        if let translated = translateTapUIDToObjectID(uid: fallbackUID) { return translated }
        if let listed = findTapFromTapList(expectedUID: fallbackUID, expectedName: expectedName) { return listed }
        return 0
    }

    private func translateTapUIDToObjectID(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToTap, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidCF = uid as CFString
        var tapID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &uidCF){ uidPtr in AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &tapID)
        }
        guard status == noErr, tapID != 0, tapID != kAudioObjectUnknown else { return nil }
        return tapID
    }

    private func findTapFromTapList(expectedUID: String, expectedName: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTapList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var taps = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &taps) == noErr else { return nil }

        for tap in taps.reversed() {
            guard tap != 0, tap != kAudioObjectUnknown else { continue }
            if tapUID(for: tap) == expectedUID || objectName(for: tap) == expectedName { return tap }
        }
        return nil
    }

    private func objectName(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let name = cfName as String? else { return nil }
        return name
    }

    // MARK: - App Controls
    func removeTarget(pid: Int32) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        let target = targets[index]

        if let ioProcID = target.ioProcID {
            _ = AudioDeviceStop(target.aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(target.aggregateDeviceID, ioProcID)
        }
        _ = AudioHardwareDestroyAggregateDevice(target.aggregateDeviceID)
        _ = AudioHardwareDestroyProcessTap(target.tapID)
        controlsByPID.removeValue(forKey: pid)
        targets.remove(at: index)
        statusMessage = "Removed \(target.displayName)"
    }

    func setMuted(pid: Int32, muted: Bool) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        targets[index].isMuted = muted
        controlsByPID[pid]?.set(muted: muted)
    }

    func setVolume(pid: Int32, volume: Float) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        let clamped = min(max(volume, 0.0), 1.0)
        targets[index].volume = clamped
        controlsByPID[pid]?.set(volume: clamped)
    }

    private func startTapIO(deviceID: AudioObjectID, control: RealtimeControl) -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, outOutputData, _ in
            let gain = control.gain

            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

            for bufferIndex in 0..<min(inBuffers.count, outBuffers.count) {
                let input = inBuffers[bufferIndex]
                var output = outBuffers[bufferIndex]
                let byteCount = min(input.mDataByteSize, output.mDataByteSize)

                guard let src = input.mData, let dst = output.mData, byteCount > 0 else { continue }
                dst.copyMemory(from: src, byteCount: Int(byteCount))

                let sampleCount = Int(byteCount) / MemoryLayout<Float>.size
                if sampleCount > 0 {
                    control.add(frames: UInt32(sampleCount / 2))
                    let floatPointer = dst.assumingMemoryBound(to: Float.self)
                    
                    var rms: Float = 0.0
                    vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(sampleCount))
                    
                    let db = 20 * log10(max(rms, 0.001))
                    let normalizedLevel = max(0.0, min(1.0, (db + 60) / 60))
                    control.set(level: Float(normalizedLevel))
                    
                    // Applies normal volume *PLUS* the Software Pre-Amp if needed
                    var localGain = gain
                    if localGain != 1.0 {
                        vDSP_vsmul(floatPointer, 1, &localGain, floatPointer, 1, vDSP_Length(sampleCount))
                    }
                }
                
                output.mDataByteSize = byteCount
                outBuffers[bufferIndex] = output
            }
        }

        if status == noErr, let ioProcID {
            _ = AudioDeviceStart(deviceID, ioProcID)
            return ioProcID
        }
        return nil
    }

    private func createAggregateDevice(tapID: AudioObjectID) -> AudioObjectID? {
        let uid = "Rohan.VMixer.Aggregate.\(UUID().uuidString)"
        guard let tapUID = tapUID(for: tapID), let outputDeviceUID = defaultOutputDeviceUID() else { return nil }

        let tapEntry: [String: Any] = [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
        let outputSubdeviceEntry: [String: Any] = [kAudioSubDeviceUIDKey: outputDeviceUID, kAudioSubDeviceDriftCompensationKey: true]

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VMixer-\(tapUID.prefix(6))",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [outputSubdeviceEntry],
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var deviceID: AudioObjectID = 0
        if AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID) == noErr, deviceID != 0 {
            return deviceID
        }
        return nil
    }

    private func tapUID(for tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        
        guard status == noErr, let uid = cfUID as String? else { return nil }
        return uid
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        
        guard status == noErr, let uid = cfUID as String? else { return nil }
        return uid
    }


    private func translatePIDToProcessObjectID(pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<Int32>.size), &pidValue, &size, &objectID) == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
    
    // MARK: - Hardware Device Management
    func fetchOutputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return }
        
        var newDevices: [AudioDevice] = []
        for deviceID in deviceIDs {
            if hasOutputChannels(deviceID: deviceID), let name = getDeviceName(deviceID: deviceID) {
                newDevices.append(AudioDevice(id: deviceID, name: name))
            }
        }
        
        outputDevices = newDevices
        selectedOutputDeviceID = getDefaultOutputDevice()
    }
    
    private func hasOutputChannels(deviceID: AudioObjectID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        ).assumingMemoryBound(to: AudioBufferList.self)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList) == noErr else { return false }
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            if buffer.mNumberChannels > 0 { return true }
        }
        return false
    }
    
    private func getDeviceName(deviceID: AudioObjectID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, ptr)
        }
        
        guard status == noErr, let deviceName = name as String? else { return nil }
        return deviceName
    }
    
    private func getDefaultOutputDevice() -> AudioObjectID {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceID) == noErr ? deviceID : 0
    }
    
    private func setDefaultOutputDevice(deviceID: AudioObjectID) {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = deviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }
    
    // MARK: - CoreAudio Event Listeners (Hardware Keys)
    private func setupSystemAudioListeners() {
        var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        updateListeningDevice()
        
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, nil) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateListeningDevice() }
        }
    }
    
    private func updateListeningDevice() {
        let deviceID = getDefaultOutputDevice()
        guard deviceID != 0, deviceID != currentListeningDeviceID else { return }
        currentListeningDeviceID = deviceID
        
        let capturedDeviceID = deviceID
        var volAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if !AudioObjectHasProperty(deviceID, &volAddress) { volAddress.mElement = 1 }
        
        AudioObjectAddPropertyListenerBlock(deviceID, &volAddress, nil) { [weak self] _, _ in
            DispatchQueue.main.async { if self?.currentListeningDeviceID == capturedDeviceID { self?.handleExternalVolumeChange() } }
        }
        
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if !AudioObjectHasProperty(deviceID, &muteAddress) { muteAddress.mElement = 1 }
        
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, nil) { [weak self] _, _ in
            DispatchQueue.main.async { if self?.currentListeningDeviceID == capturedDeviceID { self?.handleExternalMuteChange() } }
        }
    }
    
    private func handleExternalVolumeChange() {
        guard !isSyncingInternally else { return }
        let newVol = getCurrentSystemVolume()
        if abs(masterVolume - newVol) > 0.01 {
            isSyncingInternally = true
            masterVolume = newVol
            if newVol <= 0.001 && !isMasterMuted { isMasterMuted = true }
            else if newVol > 0.001 && isMasterMuted { isMasterMuted = false }
            isSyncingInternally = false
        }
    }

    private func handleExternalMuteChange() {
        guard !isSyncingInternally else { return }
        let newMute = getCurrentSystemMute()
        if isMasterMuted != newMute {
            isSyncingInternally = true
            isMasterMuted = newMute
            if newMute {
                if masterVolume > 0.001 { preMuteVolume = masterVolume }
                masterVolume = 0.0
            } else {
                if masterVolume <= 0.001 { masterVolume = preMuteVolume > 0.001 ? preMuteVolume : 0.5 }
            }
            isSyncingInternally = false
        }
    }
    
    // MARK: - CoreAudio Volume Output Writers
    private func syncSystemVolume(to value: Float) {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return }
        
        var volume = value
        let volSize = UInt32(MemoryLayout<Float>.size)
        var volAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        
        if AudioObjectHasProperty(deviceID, &volAddress) {
            AudioObjectSetPropertyData(deviceID, &volAddress, 0, nil, volSize, &volume)
        } else {
            for channel: UInt32 in 1...2 {
                volAddress.mElement = channel
                if AudioObjectHasProperty(deviceID, &volAddress) { AudioObjectSetPropertyData(deviceID, &volAddress, 0, nil, volSize, &volume) }
            }
        }
    }
    
    private func getCurrentSystemVolume() -> Float {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return 0.5 }
        
        var volume: Float = 0.5
        var volAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if !AudioObjectHasProperty(deviceID, &volAddress) { volAddress.mElement = 1 }
        if AudioObjectHasProperty(deviceID, &volAddress) { AudioObjectGetPropertyData(deviceID, &volAddress, 0, nil, &size, &volume) }
        return volume
    }
    
    private func syncSystemMute(muted: Bool) {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return }
        
        var muteValue: UInt32 = muted ? 1 : 0
        let muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &muteValue)
        } else {
            for channel: UInt32 in 1...2 {
                muteAddress.mElement = channel
                if AudioObjectHasProperty(deviceID, &muteAddress) { AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &muteValue) }
            }
        }
    }
    
    private func getCurrentSystemMute() -> Bool {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return false }
        
        var muteValue: UInt32 = 0
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if !AudioObjectHasProperty(deviceID, &muteAddress) { muteAddress.mElement = 1 }
        if AudioObjectHasProperty(deviceID, &muteAddress) { AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muteValue) }
        
        return muteValue != 0
    }
}
