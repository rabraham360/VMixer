//
//  SettingsView.swift
//  VMixer
//
//  Created by Rohan Abraham on 5/2/26.
//

import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            
            IgnoreListSettingsView()
                .tabItem { Label("Ignored Apps", systemImage: "nosign") }
        }
        .frame(width: 450, height: 300)
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    @AppStorage("autoHookEnabled") private var autoHookEnabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showDebugStatus") private var showDebugStatus = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Auto-Hooking", isOn: $autoHookEnabled)
                Text("Automatically add apps to VMixer when they play audio.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom)

            Section {
                Toggle("Launch VMixer at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {oldValue, newValue in
                        toggleLaunchAtLogin(enabled: newValue)
                    }
            }
            .padding(.bottom)

            Section {
                Toggle("Show Debug Status Bar", isOn: $showDebugStatus)
            }
        }
        .padding(20)
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error.localizedDescription)")
        }
    }
}

// MARK: - Ignore List Settings
struct IgnoreListSettingsView: View {
    @AppStorage("ignoredBundleIDs") private var ignoredBundleIDs = "com.apple.finder"
    @State private var runningApps: [(name: String, bundleID: String)] = []
    @State private var selectedBundleID: String = ""
    
    private var ignoredArray: [String] {
        ignoredBundleIDs.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apps that should never be auto-hooked.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            List {
                ForEach(ignoredArray, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button(action: { remove(bundleID: bundleID) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 120)
            .border(Color(NSColor.gridColor), width: 1)
            
            HStack {
                Picker("Add Running App:", selection: $selectedBundleID) {
                    Text("Select App...").tag("")
                    ForEach(runningApps, id: \.bundleID) { app in
                        Text("\(app.name) (\(app.bundleID))").tag(app.bundleID)
                    }
                }
                
                Button("Add") {
                    add(bundleID: selectedBundleID)
                    selectedBundleID = ""
                }
                .disabled(selectedBundleID.isEmpty)
            }
        }
        .padding()
        .onAppear { refreshRunningApps() }
    }
    
    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? bundleID, bundleID)
            }
            .reduce(into: [String: String]()) { dict, app in dict[app.bundleID] = app.name }
            .map { (name: $0.value, bundleID: $0.key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    private func add(bundleID: String) {
        let clean = bundleID.trimmingCharacters(in: .whitespaces)
        var current = ignoredArray
        if !current.contains(clean) && !clean.isEmpty {
            current.append(clean)
            ignoredBundleIDs = current.joined(separator: ",")
        }
    }
    
    private func remove(bundleID: String) {
        var current = ignoredArray
        current.removeAll { $0 == bundleID }
        ignoredBundleIDs = current.joined(separator: ",")
    }
}
