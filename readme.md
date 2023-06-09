# multiusrp

## コマンドラインオプション

* `-c jsonfile.json`

USRPの構成情報をjsonファイルから読み込みます．
`config_examples`の中を参考にしてください．

なお，次のように`-c`とは別にパラメータを指定することで構成情報を上書きして使用することもできます．
例では，`config_examples/n210_TX1_RX1_sync.json`に記載されている`tx-rate`と`rx-rate`がどのような値だとしても，実際に使用する値は両方とも10MHzになります．

```sh
$ ./multiusrp -c config_examples/n210_TX1_RX1_sync.json --tx-rate=10e6 --rx-rate=10e6
```

* `--tx-args="usrpAddrInfo..."`
送信に利用するUSRPのIPアドレス等を指定します．
複数のUSRPを使用する場合は`addr0=...,addr1=...`のように指定します．

* `--rx-args="usrpAddrInfo..."`
受信に利用するUSRPのIPアドレス等を指定します．
複数のUSRPを使用する場合は`addr0=...,addr1=...`のように指定します．


* `--settling=floatNum`
syncToPPSコマンドで，PPSに対して何秒後に送受信を再開するのかを秒数で指定します．
デフォルト値は1です．

* `--tx-rate`
送信用USRPのサンプリングレートです．

* `--rx-rate`
受信用USRPのサンプリングレートです．

* `--tx-freq`
送信用USRPのRF周波数です．

* `--rx-freq`
受信用USRPのRF周波数です．

* `--tx-gain`
送信用USRPの利得です．

* `--rx-gain`
受信用USRPの利得です．

* `--tx-ant`
送信用USRPのアンテナ設定です．


* `--rx-ant`
受信用USRPのアンテナ設定です．

* `--tx-subdev`
送信用USRPのサブデバイス設定です．

* `--rx-subdev`
受信用USRPのサブデバイス設定です．

* `--tx-bw`
送信用USRPのフィルタの帯域幅です．

* `--rx-bw`
受信用USRPのフィルタの帯域幅です．

* `--clockref`
すべてのUSRPで使用する10MHzのクロックを指定します．

* `--timeref`
すべてのUSRPで使用するPPSを指定します．

* `--timesync`
すべてのUSRPで時間同期をするのかを設定します．

* `--otw`
PCとUSRP間のデータフォーマットを指定します．

* `--tx-channels`
送信用USRPの使用チャネルを指定します．

* `--rx-channels`
受信用USRPの使用チャネルを指定します．

* `--port`
受け付けるTCP/IPポートを指定します．

* `--recv_align`
デフォルトの受信アライメント値を設定します．


## ビルド環境構築とビルド

コンテナの起動からビルドまでは次のようにします．

```
$ docker compose up -d
$ ...少し待つ...
$ docker exec -it container_name bash
$ dub build --build=release --compiler=ldc2
```

なおlibuhdのバージョンの変更等はリポジトリの中の`docker-compose.yml`や`entrypoint.sh`を参考にしてください．


## TCP/IPによるAPI

次のようなバイナリ列を送ることで制御します．

```
[コマンドid（固定長1byte）][コマンドメッセージ（可変長）]
```

簡単な例として[client/rawcommand_from_d.d](https://github.com/k3kaimu/multiusrp/blob/master/client/rawcommand_from_d.d)を参照してください．

### Transmitコマンド（id:0x54）

送信信号を送信用USRPに設定します

```
[0x54][サンプル数N（4byte）][送信機1のデータIQIQIQ...（32bit float）][送信機2のデータIQIQIQ...（32bit float）]...
```

* レスポンスなし

複数のUSRPに設定される信号の長さは同一である必要があります．
また，この命令で設定された信号の送信が終了した場合，先頭から続けて（ループして）再度送信を再開します．

### Receiveコマンド（id:0x52）

送信用USRPから受信した信号を取得します

```
[0x52][サンプル数N（4byte）]
```

* レスポンス

```
[受信機1のデータIQIQIQ...（32bit float）][受信機2のデータIQIQIQ...（32bit float）]...
```

この命令は，かならず受信アライメントに同期して受信信号を取得します．
受信アライメントが`N`，サンプリング周波数が`Fs`であれば，1回目の受信命令と2回目の受信命令で取得される先頭サンプルの時間差は`NFs`の整数倍になります．

### Shutdownコマンド

```
[0x51]
```

* レスポンスなし

この命令は制御用のプログラムをシャットダウンします．


### changeRxAlignSizeコマンド

```
[0x41][アライメントサイズN(4byte整数)]
```

* レスポンスなし

この命令は，受信処理におけるアライメントのサイズを変更します．


### skipRxコマンド

```
[0x44][スキップサンプル数N(4byte整数)]
```

* レスポンスなし

この命令は，`N`サンプルの受信信号を破棄してアライメントを`N`サンプルずらします．
たとえば，既知の遅延サンプル数`D`が分かっている場合には`D`サンプルだけスキップすれば，受信アライメントと信号の先頭が揃います．


### syncToPPSコマンド

```
[0x53]
```

* レスポンスなし

制御ソフトに接続されたすべてのUSRPをPPSに同期します．
