# 写真スライドショー

1台の画面に写真を全画面で表示します。Mac版は「写真」のアルバムを、Windows版は選択した画像フォルダを読み取ります。設定とお気に入りはアプリに保存します。

## 起動

| 配布ファイル | 対象 | 起動方法 |
| --- | --- | --- |
| `PhotoSlideshow-1.2.0-macOS-arm64.zip` | macOS 14以降、Apple Silicon | ZIPを展開し、`写真スライドショー.app` を開きます。macOSが写真へのアクセスを確認したら、許可してアルバムを選びます。 |
| `PhotoSlideshow-1.2.0-Windows-x64.zip` | Windows x64。Windows 11を想定 | ZIPをすべて展開し、同じフォルダ内の `PhotoSlideshow.exe` を開いて画像フォルダを選びます。.NETランタイムは同梱されています。 |

Mac版はアドホック署名で公証なし、Windows版はAuthenticode署名なしです。OSのセキュリティ設定により初回起動が制限される場合があります。

Windows版は選択したフォルダ直下のJPEG、PNG、BMP、GIF、TIFFを、ファイルの更新日時が古い順に表示します。フォルダごとに再開位置を保持します。両OSが管理する再開位置、お気に入り、設定はそれぞれの端末に保存されます。

## 操作

- ホイールで前後の写真へ進みます。左ボタンを押したまま下へ回すとポインタ付近を基準に拡大し、上へ回すと縮小します。写真が切り替わると収まる倍率に戻ります。
- 写真や周囲の余白をダブルクリックしてお気に入りの登録と解除を切り替えます。操作バーの星はクリックで登録できます。写真一覧でも解除できます。
- 設定から表示秒数、起動位置、画像領域、バーの上下、時計の表示・形式・位置を選びます。
- スペースで一時停止と再開、左右キーで前後移動、Escまたは戻るボタンで終了します。

## ビルド

Mac版は Swift 6 を含む Xcode Command Line Tools を使います。Windows版は .NET 10 SDK を使い、このMacでもクロスビルドできます。

```sh
zsh macOS/build.sh
dotnet publish Windows/PhotoSlideshow.csproj -c Release -r win-x64 --self-contained true -o build/win-x64
```

## 検証範囲

Mac版は Apple Silicon の macOS 27.2.1 で確認しています。ほかのmacOSの版、複数画面、異なるDPI設定、物理ホイールの機種差、長時間の消灯抑制はこの版で網羅していません。

Windows版の実行環境と確認項目はリリースノートをご覧ください。

Windows版はこのMacでビルドし、GitHub ActionsのWindows Server 2022環境で同じアプリ実装を自動検証しています。Windows 11の実機、物理マウス、長時間の自動消灯は未確認です。
