import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: RoboMasterControllerModel
    @Environment(\.dismiss) private var dismiss
    @State private var profileName = ""
    @State private var manualCommand = ""
    @State private var showShutdownConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                controlsSection
                profilesSection
                Section("入力テスト") {
                    NavigationLink { InputTestView(model: model) } label: {
                        SettingsActionLabel("入力テストを開く", systemImage: "gamecontroller.fill", color: .purple)
                    }
                    Text("テスト中はTCP通信を開始できません。画面を閉じると入力を中立へ戻します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                sshSection
                logSection
            }
            .navigationTitle("詳細設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .alert("Raspberry Piをシャットダウンしますか？", isPresented: $showShutdownConfirmation) {
                Button("シャットダウン", role: .destructive) { model.shutdownPi() }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("PiへのSSH接続を切断して電源を落とします。車輪が安全な状態であることを確認してください。") }
        }
    }

    private var connectionSection: some View {
        Section("接続") {
            Toggle("Pi側プログラムをSSHで起動", isOn: $model.autoStartReceiver)
            Text("オフの場合はPi側の受信プログラムを起動せず、TCPだけを接続します。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var controlsSection: some View {
        Section("操作設定") {
            Picker("プリセット", selection: $model.selectedProfileID) {
                Text("カスタム").tag(Optional<UUID>.none)
                ForEach(ControlProfile.presets + model.customProfiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .onChange(of: model.selectedProfileID) { _, id in
                guard let id, let profile = (ControlProfile.presets + model.customProfiles).first(where: { $0.id == id }) else { return }
                model.applyProfile(profile)
            }
            Stepper("速度上限 \(model.speedPercent)%", value: $model.speedPercent, in: 0...100, step: 5)
            Picker("非常停止", selection: $model.emergencyStopMode) {
                ForEach(EmergencyStopMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("デッドゾーン \(model.tuning.deadzone, format: .number.precision(.fractionLength(2)))")
                Slider(value: binding(\.deadzone), in: 0...0.3, step: 0.01)
            }
            VStack(alignment: .leading) {
                Text("感度 \(model.tuning.sensitivity, format: .number.precision(.fractionLength(2)))")
                Slider(value: binding(\.sensitivity), in: 0.5...2, step: 0.05)
            }
        }
    }

    private var profilesSection: some View {
        Section("カスタムプロファイル") {
            HStack {
                TextField("名前", text: $profileName)
                Button("保存") { model.saveProfile(name: profileName); profileName = "" }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(model.customProfiles) { profile in
                HStack { Text(profile.name); Spacer(); Text("\(profile.speedPercent)%").foregroundStyle(.secondary) }
                    .swipeActions { Button("削除", role: .destructive) { model.deleteProfile(profile) } }
            }
        }
    }

    private var sshSection: some View {
        Section("SSH") {
            TextField("ユーザー名", text: $model.sshUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("SSHポート", text: $model.sshPort).keyboardType(.numberPad)
            SecureField("パスワード", text: $model.sshPassword)
            Button { model.saveSSHPassword() } label: {
                SettingsActionLabel("パスワードをKeychainへ保存", systemImage: "key.fill", color: .blue)
            }
            TextField("手動SSHコマンド", text: $manualCommand, axis: .vertical).lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button { model.runManualSSH(manualCommand) } label: {
                SettingsActionLabel("手動実行", systemImage: "terminal", color: .teal)
            }
            .disabled(manualCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sshCommandRunning)
            Button(role: .destructive) { model.killPython() } label: {
                SettingsActionLabel("Python / python3 を停止", systemImage: "xmark", color: .red)
            }
            .disabled(model.sshCommandRunning)
            Button(role: .destructive) { showShutdownConfirmation = true } label: {
                SettingsActionLabel("Raspberry Piをシャットダウン", systemImage: "power", color: .red)
            }
            .disabled(model.sshCommandRunning)
            if let result = model.lastSSHResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("直前のSSH: 終了コード \(result.exitStatus)").font(.subheadline.weight(.medium))
                    Text(result.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }

    private var logSection: some View {
        Section {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.logs.isEmpty { Text("ログはまだありません").foregroundStyle(.secondary) }
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }.padding(.vertical, 4)
            }
            .frame(height: 230)
            .accessibilityLabel("ログ。新しい項目が先頭です")
            Button(role: .destructive) { model.clearLogs() } label: {
                SettingsActionLabel("ログを消去", systemImage: "trash.fill", color: .red)
            }
        } header: { Text("ログ") }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ControlTuning, T>) -> Binding<T> {
        Binding(get: { model.tuning[keyPath: keyPath] }, set: { model.tuning[keyPath: keyPath] = $0; model.selectedProfileID = nil })
    }
}

private struct SettingsActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    init(_ title: LocalizedStringKey, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize * 0.54, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct InputTestView: View {
    @ObservedObject var model: RoboMasterControllerModel
    var body: some View {
        List {
            Section("DualSense") {
                LabeledContent("状態", value: model.controllerConnected ? "検出済み" : "未検出")
                LabeledContent("左スティック", value: "X \(twoDigits(model.snapshot.leftX)) / Y \(twoDigits(model.snapshot.leftY))")
                LabeledContent("右スティック", value: "X \(twoDigits(model.snapshot.rightX)) / Y \(twoDigits(model.snapshot.rightY))")
                LabeledContent("L2 / R2", value: "\(twoDigits(model.snapshot.leftTrigger)) / \(twoDigits(model.snapshot.rightTrigger))")
            }
            Section("押されているボタン") {
                if model.snapshot.buttons.isEmpty { Text("なし").foregroundStyle(.secondary) }
                else { ForEach(model.snapshot.buttons.sorted { $0.label < $1.label }, id: \.self) { Text($0.label) } }
            }
            Section("TCP") { Text("入力テストではTCP接続は開始できません。").foregroundStyle(.secondary) }
        }
        .navigationTitle("入力テスト")
        .onAppear { model.setSettingsInput(enabled: true); model.input.reset() }
        .onDisappear { model.input.reset(); model.setSettingsInput(enabled: false) }
    }

    private func twoDigits(_ value: Double) -> String { String(format: "%.2f", value) }
}
