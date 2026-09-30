import AppKit
import SwiftUI
import SnapGeometry

final class AppState: ObservableObject {
    @Published var trusted = Accessibility.trusted
    @Published var captureAllowed = WindowThumbnails.permitted
    @Published var status = "Ready when you are."
    func check() { trusted = Accessibility.trusted; captureAllowed = WindowThumbnails.permitted }
}

struct SettingsView: View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var state: AppState
    var preview: () -> Void
    var switchWindows: () -> Void
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        Image(systemName: "rectangle.split.3x1")
                            .font(.system(size: 29, weight: .light)).foregroundStyle(.tint)
                            .frame(width: 66, height: 66)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GlassSnap").font(.system(size: 30, weight: .semibold, design: .rounded))
                            Text("A little order. A lot of space.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("LOCAL EDITION").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary)
                    }
                    permissionCard
                    VStack(alignment: .leading, spacing: 16) {
                        Text("MAKE ROOM FOR WHAT MATTERS").font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 20) {
                            instruction("1", "Lift", "Drag a window by its title bar near the top center. The layouts appear immediately.")
                            instruction("2", "Place", "Keep holding, move into a layout zone, and release.")
                            instruction("3", "Find your balance", "Snap another window into the same layout. Hover the seam and drag the glass handle.")
                        }
                        Button(action: preview) { Label("Preview the layouts", systemImage: "rectangle.3.group") }
                            .buttonStyle(.glass)
                    }.padding(20).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 18) {
                        Toggle("Enable window snapping", isOn: $preferences.enabled)
                        Divider()
                        Toggle("Shared resize handles", isOn: $preferences.dividers)
                        Toggle("Animate window placement", isOn: $preferences.animate)
                        HStack {
                            Text("Space between windows")
                            Spacer()
                            Slider(value: $preferences.gap, in: 0...20, step: 2).frame(width: 160)
                            Text("\(Int(preferences.gap)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("Outer top edge delay")
                            Spacer()
                            Picker("Outer top edge delay", selection: $preferences.edgeDelay) {
                                Text("Instant").tag(0.0)
                                Text("Quick").tag(0.12)
                                Text("Deliberate").tag(0.35)
                            }.labelsHidden().frame(width: 170)
                        }
                    }.toggleStyle(.switch).font(.system(size: 13)).padding(20)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Option+Tab window switcher", isOn: $preferences.switcherEnabled).toggleStyle(.switch)
                        Button(action: switchWindows) { Label("Open window switcher", systemImage: "rectangle.on.rectangle") }.buttonStyle(.glass)
                        Text("Hold Option and tap Tab to cycle through open windows. Release Option to switch. Click × or press ⌘W to close a window normally; save prompts stay intact.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Label(state.captureAllowed ? "Window previews enabled" : "Screen Recording access enables snapshots", systemImage: "rectangle.on.rectangle")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            if !state.captureAllowed {
                                Button("Enable previews") { WindowThumbnails.requestAccess(); state.check() }.buttonStyle(.glass)
                            }
                        }
                        Text("Captures run only while the switcher is open. Thumbnails stay in memory and are released when it closes.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.font(.system(size: 13)).padding(20)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 8) {
                        Label("One display or many. Including ultrawide.", systemImage: "display.2").font(.system(size: 12, weight: .medium))
                        Text("Nine layouts, including three columns and a wider center. Escape cancels a gesture. The menu bar also has placement and restore commands.")
                        Text("For the cleanest experience, turn off “Drag windows to menu bar to fill screen” in System Settings → Desktop & Dock, and pause other window managers.")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Circle().fill(state.trusted && preferences.enabled ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(state.status).lineLimit(2)
                        Spacer()
                        Text("0.2 · Made for your Mac").foregroundStyle(.tertiary)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(30)
            }
        }.frame(width: 620, height: 740)
    }
    private var permissionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: state.trusted ? "checkmark.shield" : "hand.raised").font(.system(size: 22)).foregroundStyle(state.trusted ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.trusted ? "Ready to arrange" : "One permission, then you’re set").font(.system(size: 13, weight: .semibold))
                Text(state.trusted ? "Accessibility is enabled. GlassSnap lives in your menu bar." : "Allow GlassSnap in Accessibility so it can move and resize your windows.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !state.trusted {
                VStack(spacing: 6) {
                    Button("Enable access") { Accessibility.requestAccess(); Accessibility.openSettings() }.buttonStyle(.glassProminent)
                    Button("Check again") { state.check() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(16).glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
    private func instruction(_ number: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 24, height: 24).background(.tint.opacity(0.1), in: Circle())
            Text(title).font(.system(size: 13, weight: .medium))
            Text(body).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
