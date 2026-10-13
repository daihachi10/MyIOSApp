# RoboMaster Controller for iPhone

Raspberry Pi上の既存 `controller_motor_receiver.py` に、USBまたはBluetooth接続したDualSenseの入力をTCPで送るSwiftUIアプリです。Pi側・STM32側のソフトウェアと8バイト通信仕様は変更しません。

> **安全上の注意**: 初回確認は必ず車輪を浮かせ、非常停止できる状態で行ってください。通信断・コントローラー切断・画面ロック・アプリのバックグラウンド移行時には、アプリが中立フレームを3回送信して切断します。バックグラウンドでの連続操作はできません。

## 必要なもの

- iOS 26以降のiPhone（iOS 27 SDKでビルド）
- USBケーブル、またはiOS設定のBluetoothで接続したDualSense
- 同一LAN上のRaspberry Pi（既存の受信プログラム）
- PiのSSHアカウント（既定ユーザー名: `daihachi`）

Bluetoothを使う場合は、先にiPhoneの「設定」→「Bluetooth」でDualSenseをペアリングしてください。アプリはGameController.frameworkを通じてUSB／Bluetoothの接続済みコントローラーを検出し、独自HIDアクセスは行いません。iOSが公開しないPS/Home、Touchpad、Muteなどの入力は機種・OSの仕様により未押下になることがあります。

## 使い方

1. iPhoneをPiと同じWi-Fiへ接続し、DualSenseをUSBまたはBluetoothで接続します。
2. アプリでPiのIPアドレスとTCPポート（既定 `5001`）を確認します。
3. 画面右上の詳細設定でSSHユーザー名・ポート・パスワードを入力し、「パスワードをKeychainへ保存」を押します。パスワードはソースコード、Git、ログ、IPAに含まれません。
4. Pi側プログラムをアプリから起動する場合は「Pi側プログラムをSSHで起動」をオンにします。起動コマンドは次の形式です。

   ```sh
   python3 -u "$HOME/DifferentialDriveRobomaster/controller_motor_receiver.py" \
     --max-rpm 12000 --max-current 4000
   ```

5. スティックを中央に戻し、DualSenseが検出されていることを確認して「接続」を押します。初回はiOSのローカルネットワーク確認で「許可」を選んでください。PingはiOSやネットワーク機器がICMPを遮断する場合があるため表示専用で、接続可否の必須条件にはしていません。

ローカルネットワークを誤って許可しなかった場合は、iPhoneの「設定」→「プライバシーとセキュリティ」→「ローカルネットワーク」からRoboMaster Controllerを許可して、もう一度「接続」を押してください。
6. Options＋Create（または設定したOptions長押し）で非常停止します。解除するにはボタンとスティックを離して「非常停止を解除」を押します。

速度上限はPiの起動引数 `--max-rpm` にだけ反映されます。TCPフレームの軸値を二重に縮小しません。

## パケット仕様

TCP接続後に、次の順で送信します。

1. ASCII `Hello Raspi!\n`
2. 中立の8バイトフレーム
3. 20 msごとの最新フレーム（50 Hz）

| Byte | 内容 |
| --- | --- |
| 0 | `AA` |
| 1 | Cross / Circle / Square / Triangle / Create / Home / Options / L3 |
| 2 | R3 / L1 / R1 / D-pad上・下・左・右 / Touchpad |
| 3 | Mute / L2 / R2 |
| 4–7 | 左X / 左Y / 右X / 右Y（`0...255`、中央 `128`） |

デッドゾーンは半径5%（詳細設定で0〜30%）、トリガーは25%を超えるとビットを立てます。切断時は中立フレームを3回送信します。非常停止はOptionsフレーム3回、続けて中立フレーム3回です。

## 詳細設定

- 操作プロファイル、速度、デッドゾーン、感度
- TCPを始めない入力テスト
- SSH手動コマンド、`pkill python; pkill python3`、Piシャットダウン
- 新しい順のログ（ログ欄だけがスクロールします）

SSHの初回LAN接続はAndroid版と互換のためホスト鍵を自動受諾します。信頼できるローカルネットワークでのみ使用してください。

## ビルドとAltStoreインストール

このリポジトリのGitHub Actions **Build iOS IPA** はXcode 27ランナーで、署名していない `Controller.ipa` を作成します。

1. `feature/robomaster-ios` をGitHubへpush、またはActionsから手動実行します。
2. 成功した実行のArtifactsから `Controller-ipa` をダウンロードします。
3. WindowsのAltServer / AltStoreでIPAを開き、Apple IDで署名してiPhoneへインストールします。

MacではXcode 27とXcodeGenを用意し、次でプロジェクトを再生成してビルドできます。

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project Controller.xcodeproj -scheme Controller -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

## 確認項目

- Unit Test: ボタン配置、トリガー、デッドゾーン、軸変換、8バイト中立フレーム、非常停止、Pi起動コマンド
- 実機: USB／Bluetooth DualSenseの左右スティック、Options、D-pad、L1/R1、L2/R2
- 実機: Pi接続、非常停止、コントローラー切断、端末ロック、Wi-Fi切断を車輪を浮かせて確認

実機のモーター動作は、環境ごとに上記の安全確認を行ってください。
