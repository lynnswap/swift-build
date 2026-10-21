# Custom Xcode Build Service ガイド

[English](GUIDE.md)

詳しい仕組みとトラブルシューティングをまとめたガイドです。インストール、更新、ローカルビルドの手順は [README](README.ja.md) を参照してください。

## status の出力を読む

`custom-xcode-build-service status` は、2 つのパッケージについて表示します。実行したコマンドが入っているパッケージと、選択中のパッケージです。Homebrew 版、複数の mise のバージョン、ローカルビルドのようにパッケージが複数あると、この 2 つは別のものになることがあります。たとえば、ローカルビルドを選択している状態で Homebrew 版のコマンドを実行すると、出力の先頭は次のようになります。

```text
Installed: v0.5.2
  Source: 456d28b99d547ff959b9e696480ada246ef2318a
  Built with Xcode: 27.0 (27A266a)
Selected service: custom
Selected custom package: v0.0.0-local (/Users/you/Library/Developer/CustomXcodeBuildServiceBuilds/1a2b3c4/payload)
  Source: 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d
  Built with Xcode: 27.1 (27A9275)
```

| 行 | 意味 |
| --- | --- |
| `Installed` | 実行したコマンドが入っているパッケージのバージョン |
| `Selected service` | 保存されている選択。`custom` か `bundled` |
| `Selected custom package` | 選択中のパッケージのバージョンとパス |
| `Source`、`Built with Xcode` | `Installed` または `Selected custom package` の下に字下げして表示される。そのパッケージのビルド元のコミットと、ビルドに使った Xcode |
| `Installed custom service` | Xcode がカスタム版のサービスを起動する固定のパス。選択中のパッケージへのリンクを経由する |
| `Launchd selection` | これから起動するアプリに、launchd の環境変数が渡すサービス |
| `XCBBUILDSERVICE_PATH`、`DisableConcurrentDependencyResolution`、`SWBBUILDSERVICE_PATH` | launchd の環境変数の現在の値 |
| `Login job` | ログイン時に選択を設定し直す LaunchAgent が読み込まれているか |
| `Running build services` | 自分のユーザーで動いているビルドサービスのプロセス。カスタム版のサービスには `[managed custom service]` が付く |

`Launchd selection` が示すのは、これから起動するアプリの設定です。すでに起動しているアプリには当てはまりません。`Running build services` には、動いているビルドサービスのプロセスが並びます。`[managed custom service]` の付いたプロセスはカスタム版のパッケージから起動したものですが、どのバージョンを読み込んだかや、どのアプリが起動したかは分かりません。

確認の一部が失敗した場合、`status` は読み取れた情報とエラーを表示し、0 以外の終了ステータスで終わります。`custom-xcode-build-service --version` は、パッケージのバージョンだけを表示します。デスクトップの設定は読みません。

## コマンドが変更するファイルと設定

`use custom` を実行すると、自分のユーザーアカウントで次の項目が変わります。

| 項目 | 変更内容 |
| --- | --- |
| launchd の環境変数 `XCBBUILDSERVICE_PATH` | `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle/SWBBuildServiceBundle` を絶対パスにして設定する。Xcode はこのパスからサービスを起動する |
| launchd の環境変数 `DisableConcurrentDependencyResolution` | `0` を設定し、依存関係の並列解決を有効にする |
| `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle` | 選択中のパッケージのサービスバンドル全体（リソースとプラグインを含む）へのリンク |
| `~/Library/LaunchAgents/io.github.lynnswap.custom-xcode-build-service.plist` | ログイン時に `activate` を実行し、環境変数を設定し直す LaunchAgent |

サービスのパスは、どのカスタム版のパッケージでも同じです。別のパッケージを選択しても、変わるのはリンクの指す先だけです。そのため、カスタム版どうしの切り替えでは、アプリを起動し直す必要がありません。

選択を記録しているのは LaunchAgent だけです。LaunchAgent があればカスタム版が選択されていて、その中のコマンドのパスが選択中のパッケージを表します。パッケージのファイルは Homebrew か mise が管理していて、コマンドはそれらをコピーも削除もしません。

`use bundled` は、2 つの環境変数と LaunchAgent を削除します。選択中のパッケージが削除されていても実行できます。`uninstall` はそれに加えて、コマンドが `~/Library/Developer/CustomXcodeBuildService` に置いているファイル（古い単体インストール版が残したファイルを含む）と、古いバージョンが作った `~/.local/bin/custom-xcode-build-service` のリンクを削除します。ディレクトリ自体は、`.lock` と `.owner` のファイルとともに残ります。Xcode、`xcodebuild`、カスタム版のサービスのどれかが動いている間は、`uninstall` は実行を拒否します。

## 実行中のサービスを止める

実行中のサービスは、起動したときに読み込んだコードを使い続けます。次のコマンドはカスタム版のサービスを止め、Xcode が次のリクエストで選択中のサービスを起動し直すようにします。Xcode と MCP のクライアントは動き続けますが、実行中のビルドやリクエストは中断されます。ビルドが終わってから実行し、中断されたリクエストはやり直してください。

どちらのコマンドも、各プロセスに終了を要求して、その PID を表示します。プロセスが終了するまでは待ちません。以前のパッケージのファイルを削除する前に、それらの PID が `status` に表示されなくなったことを確かめてください。

| コマンド | 使う場面 |
| --- | --- |
| `reload` | 選択中のパッケージが同じパスのまま入れ替わったとき（`brew upgrade` の後や、ローカルビルドをその場で置き換えた後など）。選択は変わらない。Xcode 同梱のサービスを選択している場合は何もしない |
| `use custom --reload` | 別のパッケージに切り替えるとき。実行したコマンドが入っているパッケージを選択し、それまで選択していたパッケージのサービスを止める。そのパッケージがすでに選択されている場合は何も止めないので、`reload` を使う |

止められないプロセスがあった場合も、新しい選択はそのまま残り、エラーに止められなかったプロセスが表示されます。選択に失敗した場合は、どのサービスも止まりません。パッケージをインストールしたりアップグレードしたりしても、選択は変わりません。

`brew upgrade` の前から動いているサービスは、`reload` で止めるか自然に終了するまで、古いバージョンのコードを使い続けます。Homebrew は既定ではアップグレードの際に古いバージョンのファイルを削除するので、アップグレードしたらすぐに `reload` を実行してください。

## SSH から切り替える

`use custom`、`use bundled`、`uninstall` は macOS のデスクトップセッションの設定を変えるので、デスクトップにログインしている必要があります。デスクトップセッションで実行する場合、管理者の認証はいりません。SSH などのバックグラウンドセッションから実行すると、コマンドは `sudo` を求め、デスクトップセッションに入ってから、元のユーザーとして設定を変えます。

`status` が認証を求めることはありません。バックグラウンドセッションからデスクトップの設定を読むには、`sudo` を付けてフルパスで実行します。

```sh
sudo "$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" status
```

## mise のアーカイブを検証する

`mise lock` が項目を作るとき、mise はアーカイブをリリースの GitHub attestation と照合し、`provenance = "github-attestations"` を記録します。GitHub attestation は、アーカイブがこのリポジトリのリリースのものであることを示す、GitHub の署名付きの記録です。項目にこの行がない場合、mise は照合していません（mise の設定で照合を無効にしている場合など）。その場合は、`checksum` をリリースの `SHA256SUMS.txt` にあるアーカイブの値と比べるか、リリースからアーカイブをダウンロードして GitHub CLI で確かめます。

```sh
gh release verify-asset vX.Y.Z custom-xcode-build-service-darwin-arm64.tar.gz -R lynnswap/swift-build
```

## ローカルビルドのオプションと動作確認

`release.py build` のオプション:

| オプション | 説明 |
| --- | --- |
| `--version` | `status` に表示するバージョン。`v1.2.3` か `v1.2.3-label` の形式で指定する |
| `--output-dir` | ソースのコピー、ビルド中のファイル、`payload` を置くディレクトリ。存在しないか空である必要がある |
| `--revision` | ビルドするコミット。既定値は `HEAD` |
| `--jobs` | 並列で実行するビルドジョブの数。既定値は 2 |

選択する前にビルドを確かめるには、その `payload` ディレクトリに対して `verify-payload` を実行します。選択は変わりません。確認する内容は[テストの節](#コマンドと配布物をテストする)で説明しています。

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py verify-payload \
  --payload /path/to/build/payload
```

## トラブルシューティング

| 症状 | 対処 |
| --- | --- |
| ログインした後、Xcode が Xcode 同梱のサービスを使っている | macOS は、LaunchAgent が環境変数を設定する前に Xcode を開くことがあります。`status` を実行し、`Launchd selection` がカスタム版を示していれば、Xcode を起動し直します。 |
| MCP からのリクエストが以前のサービスを使っている | Xcode Service（MCP 用）はバックグラウンドで動き、Xcode や AI アプリを閉じても残ることがあります。切り替えた後にアプリを起動し直すときは、アクティビティモニタなどで Xcode Service も終了します。 |
| 選択中のパッケージを削除してしまい、Xcode がカスタム版のサービスを起動できない | 再インストールした Homebrew 版など、手元にあるどれかのコマンドで `use bundled` を実行します。`use bundled` は、選択中のパッケージがなくても動きます。LaunchAgent が削除されたコマンドを指したままなので、選択はひとりでには戻りません。 |

## 単体インストール版から移行する

`custom-v*` のタグが付いた古いリリースは、単体のインストーラーでインストールし、コマンドを `~/.local/bin/custom-xcode-build-service` に置いていました。Homebrew か mise に移行する手順は次のとおりです。

1. Homebrew か mise で、現在のリリースをインストールします。
2. 新しいパッケージのコマンドで `use custom` を実行します。`PATH` 上の古いコマンドを使わないよう、Homebrew のフルパスか `mise exec --` で実行します。
3. Xcode、Xcode Service（MCP 用）、ターミナルアプリ、AI エージェントのアプリを起動し直します。

`use custom` は、選択を新しいパッケージに移し、古いコマンドのリンクを削除します。古いファイルは残るので、実行中のサービスは動き続けます。それらのサービスをすぐに止めたい場合は、ビルドが終わってから、手順 2 で `use custom --reload` を実行します。移行に失敗した場合、コマンドは変更を元に戻します。

## コマンドと配布物をテストする

コマンドはリポジトリのルートで実行します。

管理コマンドと配布スクリプトのテスト:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

`release.py verify-payload --payload <パッケージ>` は、インストール済みのパッケージに対してスモークテストを実行します。構成と署名を確認し、そのパッケージのサービスを使って Xcode のビルドとパッケージのテストを実行します。さらに、サービスのパスを設定した状態でも `swift build`、`swift run`、`swift test` が動くことを確かめます。これらのコマンドでは、SwiftPM は内蔵のエンジンを使います。`<パッケージ>` には次のパスを指定します。

- ローカルビルド: `/path/to/build/payload`（`/path/to/build` は `release.py build` の出力先）
- Homebrew: `$(brew --prefix custom-xcode-build-service)/libexec`
- mise: `mise where github:lynnswap/swift-build` が表示するディレクトリ

`brew test custom-xcode-build-service` が確認するのは、バージョンとヘルプの出力だけです。Xcode がパッケージのマニフェストを読み込むには専用のサンドボックスが必要なので、Xcode との結合テストは Homebrew のテスト用サンドボックスの外で、`verify-payload` が実行します。

リリース用のアーカイブをテストするには、ローカルビルドからリリースのアセットを作ります。

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py package \
  --build-dir /path/to/build --output-dir /path/to/release
```

作ったディレクトリを指定して、`Utilities/CustomXcodeBuildService/Distribution` にある次のスクリプトを実行します。

| コマンド | 確認する内容 |
| --- | --- |
| `release.py verify --release-dir /path/to/release` | 選択中の Xcode で、チェックサム、アーカイブの構成、署名を確認し、スモークテストを実行する |
| `verify_xcodes.py --release-dir /path/to/release` | 同じ確認を、`/Applications` にある Xcode 26・27 の各リリース版と最新のベータ版で実行する |
| `test-homebrew.sh /path/to/release` | Homebrew でアーカイブをインストールし、`verify-payload` を実行する。パッケージがインストール済みの場合は実行しない |
| `test-mise.py /path/to/release` | 一時ディレクトリを使って mise でアーカイブをインストールし、`verify-payload` を実行する |

どの確認も、選択は変えません。サービスのパスを設定するのは、確認で起動する子プロセスだけです。

サービスが依存するパッケージのバージョンは、`Distribution/ServiceDependencies.resolved` で固定しています。

CI は、プルリクエストとリリースごとに、`xcode-27` のランナーでアーカイブを 1 つビルドします。そのアーカイブを、`macos-26` と `xcode-27` のランナーで Xcode 26、Xcode 27、最新のベータ版と組み合わせてテストします。Homebrew と mise でインストールできることも確かめます。
