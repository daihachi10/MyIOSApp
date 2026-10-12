# MyIOSApp

SwiftUI で作成したシンプルな iPhone アプリです。

## 機能

- 起動時に `Hello iPhone!` を表示
- `Count Up` ボタンを押すとカウントアップ
- iOS のシステム外観設定に追従するダークモード対応

## 起動方法

1. macOS の Xcode で `MyIOSApp.xcodeproj` を開く
2. Signing & Capabilities で自分の開発チームを選択する
3. iPhone シミュレータまたは接続した iPhone を選択して Run

対応デプロイメントターゲットは iOS 16.0 以降です。

## Windows から IPA を作る場合

GitHub Actions の `Build iOS IPA` ワークフローが macOS ランナーで未署名 IPA を作成し、Actions の成果物として公開します。

1. このリポジトリを GitHub に push する
2. GitHub の Actions から `Build iOS IPA` を手動実行する
3. 完了後、Artifacts の `MyIOSApp-ipa` をダウンロードする
4. Windows の AltServer / AltStore で IPA を読み込み、Apple ID で署名して iPhone にインストールする

未署名 IPA の作成には Apple Developer 証明書を使用しません。署名は AltServer 側で行います。
