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
    
    // MARK: - Realtime Control
    private final class RealtimeControl {
        private var lock = os_unfair_lock_s()
        private var _volume: Float = 1.0
        private var _muted = false
        private var _lastFrameCount: UInt64 = 0
        private var _currentLevel: Float = 0.0
        
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

    // MARK: - Models
    struct Target: Identifiable {
        let id: Int32
        let pid: Int32
        var displayName: String
        let bundleID: String?
        var tapID: AudioObjectID
        var aggregateDeviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID?
        var volume: Float
        var isMuted: Bool
        var level: Float = 0.0
        var icon: NSImage?
        var isHidden: Bool = false
    }

    struct RunningApp: Identifiable, Hashable {
        let pid: Int32
        let name: String
        let bundleID: String?

        var id: Int32 { pid }
        var title: String {
            if let bundleID, !bundleID.isEmpty {
                return "\(name) (\(bundleID))"
            }
            return name
        }
    }

    // MARK: - Published State
    @Published private(set) var targets: [Target] = []
    @Published private(set) var runningApps: [RunningApp] = []
    @Published var statusMessage = "Ready"
    
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
            if !isSyncingHardware { setSystemMute(isMuted: isMasterMuted) }
        }
    }
    
    private var selectedOutputDeviceID: AudioObjectID = 0
    private var isSyncingHardware = false
    
    private var controlsByPID: [Int32: RealtimeControl] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var pollingTask: Task<Void, Never>?

    // MARK: - Initialization
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
        if audioStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { print("Microphone permission denied!") }
            }
        } else if audioStatus == .denied || audioStatus == .restricted {
            statusMessage = "Microphone permission is blocked in System Settings."
        }
        
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
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                
                let defaults = UserDefaults.standard
                let autoHookEnabled = defaults.object(forKey: "autoHookEnabled") as? Bool ?? true
                guard autoHookEnabled else { return }
                
                let ignoredString = defaults.string(forKey: "ignoredBundleIDs") ?? "com.apple.finder"
                let ignoredBundleIDs = Set(ignoredString.split(separator: ",").map(String.init))
                
                if let bundleID = app.bundleIdentifier, ignoredBundleIDs.contains(bundleID) { return }
                if self.targets.contains(where: { $0.pid == app.processIdentifier }) { return }
                
                let runningApp = RunningApp(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleID: app.bundleIdentifier
                )
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
            .filter { $0.processIdentifier > 0 }
            .filter { !$0.isTerminated }
            .compactMap { app -> RunningApp? in
                let pid = Int32(app.processIdentifier)
                guard pid > 0 else { return nil }
                if pid == Int32(ProcessInfo.processInfo.processIdentifier) {
                    return nil
                }

                let localizedName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackName = app.bundleIdentifier ?? "PID \(pid)"
                let safeName = localizedName.isEmpty ? fallbackName : localizedName
                return RunningApp(pid: pid, name: safeName, bundleID: app.bundleIdentifier)
            }
            .reduce(into: [Int32: RunningApp]()) { acc, app in
                acc[app.pid] = app
            }
            .map(\.value)
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
    private func createTapWithFallback(pid: Int32, bundleID: String?) -> (tapID: AudioObjectID, usedBundleFallback: Bool)? {
        
        if let bundleID, !bundleID.isEmpty {
            var bundleTapID: AudioObjectID = 0
            let bundleDescription = CATapDescription()
            bundleDescription.uuid = UUID()
            
            var bundlesToTap = [bundleID]
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
            case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
                bundlesToTap.append("\(bundleID).helper")
                bundlesToTap.append("\(bundleID).helper.renderer")
                bundlesToTap.append("\(bundleID).helper.plugin")
            case "org.mozilla.firefox":
                bundlesToTap.append("org.mozilla.plugincontainer")
            default:
                break
            }
            
            bundleDescription.bundleIDs = bundlesToTap
            bundleDescription.isMixdown = true
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
                statusMessage = "Tap was created but UID lookup failed."
                return nil
            } else {
                print("AudioHardwareCreateProcessTap by PID failed for \(pid) with OSStatus: \(status)")
            }
        }

        statusMessage = "PID \(pid) cannot be tapped by PID."
        return nil
    }

    private func normalizedTapID(_ tapID: AudioObjectID, fallbackUID: String, expectedName: String) -> AudioObjectID {
        if tapID != 0, tapID != kAudioObjectUnknown {
            return tapID
        }
        if let translated = translateTapUIDToObjectID(uid: fallbackUID) {
            return translated
        }
        if let listed = findTapFromTapList(expectedUID: fallbackUID, expectedName: expectedName) {
            return listed
        }
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var taps = Array(repeating: AudioObjectID(0), count: count)
        let dataStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &taps)
        guard dataStatus == noErr else { return nil }

        for tap in taps.reversed() {
            guard tap != 0, tap != kAudioObjectUnknown else { continue }
            let uid = tapUID(for: tap)
            let name = objectName(for: tap)
            if uid == expectedUID || name == expectedName {
                return tap
            }
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
        statusMessage = muted ? "Muted \(targets[index].displayName)." : "Unmuted \(targets[index].displayName)."
        
        // Link: Mute the hidden daemon if FaceTime is muted
        if targets[index].bundleID == "com.apple.FaceTime" {
            if let dIndex = targets.firstIndex(where: { $0.bundleID == "com.apple.avconferenced" }) {
                let dPID = targets[dIndex].pid
                targets[dIndex].isMuted = muted
                controlsByPID[dPID]?.set(muted: muted)
            }
        }
    }

    func setVolume(pid: Int32, volume: Float) {
        guard let index = targets.firstIndex(where: { $0.pid == pid }) else { return }
        let clamped = min(max(volume, 0.0), 1.0)
        targets[index].volume = clamped
        controlsByPID[pid]?.set(volume: clamped)
        
        // Link: Adjust the hidden daemon volume if FaceTime volume changes
        if targets[index].bundleID == "com.apple.FaceTime" {
            if let dIndex = targets.firstIndex(where: { $0.bundleID == "com.apple.avconferenced" }) {
                let dPID = targets[dIndex].pid
                targets[dIndex].volume = clamped
                controlsByPID[dPID]?.set(volume: clamped)
            }
        }
    }

    private func startTapIO(deviceID: AudioObjectID, control: RealtimeControl) -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, outOutputData, _ in
            let gain = control.gain

            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            
            var maxLevel: Float = 0.0

            for bufferIndex in 0..<min(inBuffers.count, outBuffers.count) {
                let input = inBuffers[bufferIndex]
                var output = outBuffers[bufferIndex]
                let byteCount = min(input.mDataByteSize, output.mDataByteSize)

                guard let src = input.mData, let dst = output.mData, byteCount > 0 else { continue }
                dst.copyMemory(from: src, byteCount: Int(byteCount))

                let frameCount = Int(byteCount) / MemoryLayout<Float>.size
                if frameCount > 0 {
                    control.add(frames: UInt32(frameCount))
                }
                
                let floatPointer = dst.bindMemory(to: Float.self, capacity: frameCount)
                
                var rms: Float = 0.0
                vDSP_rmsqv(floatPointer, 1, &rms, vDSP_Length(frameCount))
                let db = 20 * log10(max(rms, 0.001))
                let normalizedLevel = max(0.0, min(1.0, (db + 60) / 60))
                maxLevel = max(maxLevel, Float(normalizedLevel))
                
                if gain != 1.0 {
                    var mutableGain = gain
                    vDSP_vsmul(floatPointer, 1, &mutableGain, floatPointer, 1, vDSP_Length(frameCount))
                }
                output.mDataByteSize = byteCount
                outBuffers[bufferIndex] = output
            }
            
            control.set(level: maxLevel)
        }

        guard status == noErr, let ioProcID else { return nil }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            return nil
        }

        return ioProcID
    }

    private func createAggregateDevice(tapID: AudioObjectID) -> AudioObjectID? {
        let uid = "Rohan.VMixer.Aggregate.\(UUID().uuidString)"
        guard let tapUID = tapUID(for: tapID) else { return nil }
        guard let outputDeviceUID = defaultOutputDeviceUID() else { return nil }

        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let outputSubdeviceEntry: [String: Any] = [
            kAudioSubDeviceUIDKey: outputDeviceUID
        ]

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
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        return deviceID
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var pidValue = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<Int32>.size),
            &pidValue,
            &size,
            &objectID
        )

        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
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
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }
    
    func setSystemVolume(to value: Float) {
        let deviceID = selectedOutputDeviceID
        guard deviceID != 0 else { return }
        
        var volume = value
        let dataSize = UInt32(MemoryLayout<Float>.size)
        
        // Try Virtual Service First
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioHardwareServiceSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume) == noErr { return }
        
        // Try Raw Hardware Next
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume) == noErr { return }
        
        // Split L/R channels for stuboorn hardware
        address.mElement = 1
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume)
        address.mElement = 2
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &volume)
    }
    
    func setSystemMute(isMuted: Bool) {
        let deviceID = selectedOutputDeviceID
        guard deviceID != 0 else { return }

        var mutedInt: UInt32 = isMuted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt) == noErr { return }
        
        address.mElement = 1
        let lStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt)
        address.mElement = 2
        let rStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &mutedInt)
        
        if lStatus == noErr || rStatus == noErr { return }
        
        setSystemVolume(to: isMuted ? 0.0 : masterVolume)
    }
    
    private func handleDeviceChange() {
        print("Output device changed! Re-routing audio...")
        
        let activeApps = targets.map { (pid: $0.pid, name: $0.displayName, bundleID: $0.bundleID) }
        
        for app in activeApps {
            removeTarget(pid: app.pid)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            for app in activeApps {
                self?.addTarget(pid: app.pid, name: app.name, bundleID: app.bundleID)
            }
        }
    }
}
