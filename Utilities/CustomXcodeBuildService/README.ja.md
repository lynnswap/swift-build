# Custom Xcode Build Service

[English](README.md)

Xcode のビルドサービスを、このフォーク（[lynnswap/swift-build](https://github.com/lynnswap/swift-build)）でビルドした Swift Build に切り替えるツールです。Xcode 同梱のサービスにまだない修正や機能を使えます。変更内容は [Releases](https://github.com/lynnswap/swift-build/releases) を参照してください。

切り替えには `custom-xcode-build-service` コマンドを使います。選択は macOS のユーザー単位ですべてのプロジェクトに適用され、GUI 側と Background 側の launchd の両方に設定されます。ログインし直しても維持されます。Xcode 本体は変更しません。

動作環境:

- macOS 26 以降の Apple Silicon 搭載 Mac
- Xcode（Xcode 26・27 と最新のベータ版で動作を確認）

入手方法:

- [Homebrew](#homebrew-でインストールする): 自分の Mac で使う
- [mise](#mise-でインストールする): プロジェクトでバージョンを固定し、メンバー全員で同じものを使う
- [ローカルビルド](#ローカルでビルドして使う): リリース前の変更を試す

## Homebrew でインストールする

1. パッケージをインストールします。

   ```sh
   brew install lynnswap/tap/custom-xcode-build-service
   ```

2. Homebrew 版を選択します。

   ```sh
   "$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
   ```

3. Xcode、Xcode Service（MCP 用）、ターミナル、AI エージェントを起動し直します。

## mise でインストールする

`mise.lock` でバージョンとチェックサムを固定し、プロジェクトのメンバー全員が同じアーカイブを使います。コマンドはプロジェクトのディレクトリで実行します（mise 2026.10.3 で確認）。

1. `mise.toml` に追加します。`X.Y.Z` は、[リリース](https://github.com/lynnswap/swift-build/releases)のバージョンから先頭の `v` を除いた値です。

   ```toml
   [tools]
   "github:lynnswap/swift-build" = "X.Y.Z"
   ```

2. `mise.lock` を作ります。

   ```sh
   mise lock --platform macos-arm64 github:lynnswap/swift-build
   ```

   追加された項目に `provenance = "github-attestations"` があることを確認します。ない場合は、`checksum` をリリースの `SHA256SUMS.txt` にあるアーカイブの値と照合します。

3. インストールして選択します。

   ```sh
   mise install --locked github:lynnswap/swift-build
   mise exec -- custom-xcode-build-service use custom
   ```

4. Xcode、Xcode Service（MCP 用）、ターミナル、AI エージェントを起動し直します。
5. `mise.toml` と `mise.lock` をコミットします。

インストールしただけでは選択は変わりません。ほかのメンバーも、各自の Mac で手順 3 と 4 を実行します。

## 切り替えと再起動

- `use custom` は、実行したコマンドが入っているパッケージを選択します。`status`、`reload`、`use bundled`、`uninstall` は、インストール済みのどのコピーから実行しても同じです。
- Xcode 同梱のサービスとカスタム版を切り替えたら、Xcode、Xcode Service（MCP 用）、ターミナル、AI エージェントを起動し直します。ターミナルで使うエージェントは、起動し直したターミナルから起動します。
- tmux を使う場合は、作業を保存して既存のサーバーを停止し、起動し直したターミナルで新しいサーバーを起動します。ペインを追加してもサーバーの環境変数は更新されません。
- カスタム版どうしの切り替えでは、起動し直す必要はありません。`use custom --reload` で以前のサービスに終了を要求すると、次のリクエストから新しいサービスが使われます。
- `reload` と `--reload` は終了を要求するだけで、終了するまでは待ちません。古いパッケージは、表示された PID が `status` に出なくなってから削除します。
- `swift build` などの SwiftPM のコマンドには影響しません。

コマンドが `PATH` にない場合は、mise ならプロジェクトのディレクトリで `mise exec --` を付けて実行し、ローカルビルドなら `payload/bin/custom-xcode-build-service` をフルパスで実行します。

## 選択中のサービスを確認する

```sh
custom-xcode-build-service status
```

`Selected service: custom` なら、カスタム版が選択されています。`Selected custom package` にはバージョンとパスが、その下の `Source` にはビルド元のコミットが表示されます。動いているサービスの見方は[ガイド](GUIDE.ja.md#status-の出力を読む)を参照してください。

## 更新する

実行中のビルドが終わってから更新します。次の手順は、動いているカスタム版のサービスに終了を要求します。Xcode を起動し直す必要はありません。中断されたリクエストはやり直してください。

### Homebrew

Homebrew 版を選択している場合は、次を実行します。

```sh
brew update
brew upgrade lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service reload
```

別のパッケージから Homebrew 版に切り替える場合は、最後の行の代わりに次を実行します。

```sh
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom --reload
```

### mise

1. `mise.toml` のバージョンを変えます。
2. `mise lock --platform macos-arm64 github:lynnswap/swift-build` を実行し、インストールのときと同じように確認します。
3. インストールして選択します。

   ```sh
   mise install --locked github:lynnswap/swift-build
   mise exec -- custom-xcode-build-service use custom --reload
   ```

4. `mise.toml` と `mise.lock` をコミットします。ほかのメンバーは、変更を取り込んでから手順 3 を実行します。

リリースに問題がある場合は、[Xcode 同梱のサービスに戻す](#xcode-同梱のサービスに戻す)か、mise で以前のバージョンを指定し直します。Homebrew で入手できるのは最新のリリースだけです。

## ローカルでビルドして使う

自分のビルドを普段の Xcode で使う手順です。選択を変えずにコミット前の変更を試すだけなら、[`launch-xcode`](../../README.md#with-xcode) か [`run-xcodebuild`](../../README.md#with-xcodebuild) のプラグインを使います。

`xcode-select` か `DEVELOPER_DIR` で Xcode 27 以降を選びます。ビルドに入るのはコミット済みのファイルだけなので、先に変更をコミットしてください（ローカルブランチで構いません）。

1. リポジトリのルートでビルドします。

   ```sh
   build_dir="$HOME/Library/Developer/CustomXcodeBuildServiceBuilds/$(git rev-parse --short HEAD)"
   python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
     --version v0.0.0-local --output-dir "$build_dir"
   ```

   パッケージは `$build_dir/payload` にできます。失敗した場合は、やり直す前に `$build_dir` を削除します。

2. 実行中のビルドが終わってから、ローカルビルドを選択します。

   ```sh
   "$build_dir/payload/bin/custom-xcode-build-service" use custom --reload
   ```

   Xcode 同梱のサービスから切り替えた場合は、Xcode などのアプリを[起動し直します](#切り替えと再起動)。

選択している間は `$build_dir` を削除しないでください。ビルドのオプションと、切り替える前に動作を確かめる方法は[ガイド](GUIDE.ja.md#ローカルビルドのオプションと動作確認)にあります。

### 変更を加えて再ビルドする

変更をコミットして、手順 1 と 2 を繰り返します。ディレクトリ名にコミットを使うので、出力先はコミットごとに変わります。前のディレクトリは、`--reload` が表示した PID が `status` に出なくなってから削除します。

### リリース版に戻す

リリース版のコマンドで `use custom --reload` を実行します。表示された PID が `status` に出なくなったら、ローカルビルドのディレクトリを削除します。

```sh
# Homebrew
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom --reload

# mise（プロジェクトのディレクトリで実行）
mise exec -- custom-xcode-build-service use custom --reload
```

## Xcode 同梱のサービスに戻す

```sh
custom-xcode-build-service use bundled
```

Xcode などのアプリを[起動し直します](#切り替えと再起動)。パッケージは残ります。

## アンインストールする

1. Xcode と Xcode Service（MCP 用）を終了し、コマンドラインのビルドとカスタム版のサービスが終わるのを待ちます。どれかが動いている間は、`uninstall` は拒否されます（[確認方法](GUIDE.ja.md#status-の出力を読む)）。
2. コマンドが追加した設定とファイルを削除し、Xcode 同梱のサービスに戻します。

   ```sh
   custom-xcode-build-service uninstall
   ```

3. パッケージを削除します。手順 2 より前に削除すると、Xcode はカスタム版のサービスを起動できなくなります。
   - Homebrew: `brew uninstall custom-xcode-build-service`
   - mise: `mise uninstall github:lynnswap/swift-build@X.Y.Z`。プロジェクトからも外す場合は、`mise unuse github:lynnswap/swift-build` と `mise lock` を実行してコミットします。
   - ローカルビルド: ディレクトリを削除します。
4. ターミナルと AI エージェントを起動し直します。

## 詳しい情報

- [ガイド](GUIDE.ja.md): 仕組み、`status` の読み方、トラブルシューティング、テスト
- [リリース手順](RELEASING.md)（メンテナー向け、英語のみ）
- `custom-xcode-build-service --help`: すべてのコマンド
