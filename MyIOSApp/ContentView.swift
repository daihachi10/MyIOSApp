import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = RoboMasterControllerModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            primaryColumn.frame(maxWidth: 460)
                            InputMonitorCard(model: model).frame(maxWidth: 460)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        VStack(spacing: 16) { primaryColumn; InputMonitorCard(model: model) }
                    }
                    .padding(.horizontal, geometry.size.width > 700 ? 24 : 16)
                    .padding(.vertical, 12)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Controller")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("詳細設定", systemImage: "gearshape") { showSettings = true }
                        .accessibilityHint("SSH、操作プロファイル、ログの詳細設定を開きます")
                        .liquidGlassCircle()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
                    .onAppear { model.setSettingsInput(enabled: false); model.input.reset() }
                    .onDisappear { model.setSettingsInput(enabled: true) }
            }
        }
        .onChange(of: scenePhase) { _, newValue in model.scenePhaseChanged(newValue) }
    }

    @ViewBuilder private var primaryColumn: some View {
        VStack(spacing: 16) {
            StatusCard(model: model)
            if !model.connectionStatus.isActive { DestinationCard(model: model) }
            if let error = model.errorText { ErrorCard(message: error) }
        }
    }
}

private struct StatusCard: View {
    @ObservedObject var model: RoboMasterControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Status", systemImage: model.connectionStatus.isActive ? "dot.radiowaves.left.and.right" : "power")
                .font(.headline)
            StatusRow(title: "Controller", value: model.controllerConnected ? "DualSense" : "未検出", symbol: "gamecontroller")
            StatusRow(title: "Raspberry Pi", value: model.raspberryPiLabel, symbol: "cpu")
            StatusRow(title: "TCP", value: model.connectionStatus.label, symbol: "network")
            if model.sendErrorCount > 0 { Text("送信エラー \(model.sendErrorCount)件").font(.footnote).foregroundStyle(.orange) }
            if model.emergencyStopped { Button("非常停止を解除", systemImage: "checkmark.shield") { model.clearEmergencyStop() }.buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).liquidCard()
        .accessibilityElement(children: .combine)
    }
}

private struct StatusRow: View {
    let title: String; let value: String; let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary); Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}

private struct DestinationCard: View {
    @ObservedObject var model: RoboMasterControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("接続先", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            TextField("Raspberry PiのIPまたはホスト名", text: $model.host).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL).keyboardType(.URL).textFieldStyle(.roundedBorder).accessibilityLabel("Raspberry Piホスト")
            TextField("ポート", text: $model.port).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("TCPポート")
            Button { Task { await model.begin() } } label: { Label("接続", systemImage: "link").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large).disabled(!model.canConnect)
                .accessibilityHint("DualSense、中央スティック、PiへのPing応答が必要です")
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).liquidCard()
    }
}

private struct InputMonitorCard: View {
    @ObservedObject var model: RoboMasterControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("入力モニター", systemImage: "dot.scope").font(.headline); Spacer()
                if model.connectionStatus.isActive { Button("切断", systemImage: "stop.fill") { Task { await model.disconnect() } }.buttonStyle(.glass).tint(.red) }
            }
            HStack(spacing: 12) {
                StickReadout(name: "左", x: model.snapshot.leftX, y: model.snapshot.leftY)
                StickReadout(name: "右", x: model.snapshot.rightX, y: model.snapshot.rightY)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ボタン").font(.subheadline).foregroundStyle(.secondary)
                if model.snapshot.buttons.isEmpty { Text("入力なし").foregroundStyle(.secondary) }
                else { FlowLayout(spacing: 6) { ForEach(model.snapshot.buttons.sorted { $0.label < $1.label }, id: \.self) { Text($0.label).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4).background(.tertiary, in: Capsule()) } } }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("送信パケット").font(.subheadline).foregroundStyle(.secondary)
                Text(model.lastPacketHex).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18).liquidCard()
        .accessibilityElement(children: .contain)
    }
}

private struct StickReadout: View {
    let name: String; let x: Double; let y: Double
    var body: some View {
        VStack(spacing: 4) {
            Text("\(name)スティック").font(.caption).foregroundStyle(.secondary)
            Text("X \(x, format: .number.precision(.fractionLength(2)))")
            Text("Y \(y, format: .number.precision(.fractionLength(2)))")
        }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ErrorCard: View {
    let message: String
    var body: some View { Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("エラー: \(message)") }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { let width = proposal.width ?? 300; var point = CGPoint.zero; var maxY: CGFloat = 0; for view in subviews { let size = view.sizeThatFits(.unspecified); if point.x + size.width > width { point.x = 0; point.y += maxY + spacing; maxY = 0 }; maxY = max(maxY, size.height); point.x += size.width + spacing }; return .init(width: width, height: point.y + maxY) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { var point = bounds.origin; var rowHeight: CGFloat = 0; for view in subviews { let size = view.sizeThatFits(.unspecified); if point.x + size.width > bounds.maxX { point.x = bounds.minX; point.y += rowHeight + spacing; rowHeight = 0 }; view.place(at: point, proposal: .unspecified); rowHeight = max(rowHeight, size.height); point.x += size.width + spacing } }
}

private extension View {
    @ViewBuilder func liquidCard() -> some View { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).glassEffect(.regular, in: .rect(cornerRadius: 24)) }
    @ViewBuilder func liquidGlassCircle() -> some View { self.labelStyle(.iconOnly).frame(width: 42, height: 42).buttonStyle(.glass).glassEffect(.regular, in: .circle) }
}
