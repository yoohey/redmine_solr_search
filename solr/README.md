# Solrの設定

プラグインが前提とするSolr（SolrCloud 9.x・10.x。9.10.1で開発）の設定。フィールドの仕様と、何がどのフィールドに入るかは[docs/schema.md](../docs/schema.md)。

## 構成

| 場所 | 中身 |
|---|---|
| `configsets/redmine/conf/` | `redmine`コレクション（Redmineのデータ）のconfigset |
| `configsets/src/conf/` | 外部ソースのコレクション（`src_12`、`src_13`…）のconfigset。すべての外部ソースで共有する |
| `common/` | 2つのconfigsetの共通部分。検索の条件に使うフィールドと型（`common-types.xml`・`common-fields.xml`）と、それらが使うファイル（`lang/`、正規化の置換表`mapping-ja.txt`、同義語の一覧`synonyms-ja.txt`） |
| `gen-mapping-ja.py` | `common/mapping-ja.txt`を作るスクリプト。`common/`の中身はすべてアップロードされるので、外に置いている。`python3 gen-mapping-ja.py > common/mapping-ja.txt` |

- **Solrのすべてのノードで`analysis-extras`モジュールを有効にする**（環境変数`SOLR_MODULES=analysis-extras`）。共通の型がICUの正規化を使うので、無効だとコレクションが読み込めない。

- 各configsetの`schema.xml`は、共通部分をXIncludeで取り込む。取り込むファイルは同じconfigsetの中にある必要があるので、**アップロードの前に`common/`の中身を各configsetの`conf/`へコピーする**。`configsets/*/conf/`をそのまま上げると、スキーマが読めずにコレクションが作れない。
- スキーマは書き換え不可にしている（`solrconfig.xml`の`ClassicIndexSchemaFactory`）。フィールドを変えるときは、ここのファイルを直してアップロードし、コレクションをリロードする。Schema APIや管理画面からは変えられない。
- gitが正本なので、`init.sh`はアップロードのときに、ここにないファイルをZooKeeperから消す。Config API・Request Parameters APIで書いた設定（`configoverlay.json`・`params.json`）も消えるので、これらのAPIは使わない。
- `common/`と`configsets/*/conf/`に同じ名前のファイルがあると、`init.sh`は止まる（共通部分で黙って上書きしないため）。
- 検索の条件に使うフィールドは`common/`に置く。configsetごとの`schema.xml`には、返すだけのフィールド（`fl`）だけを置く。
- `src`の`solrconfig.xml`には、すべての更新に効く処理（`external-document`）がある。送られた`source`・`type`・`group_id`を捨て、そのコレクションの名前、`file`、`id`の値を付ける。`file_extension`・`file_dir_1`〜`file_dir_6`も`id`から作り直し、`title`・`content`の制御文字を除く（なりすまし対策）。`redmine`にはない。2つの`solrconfig.xml`は、ここだけが違う。

## アップロードのしかた

同梱のDockerでは、`docker/`で`docker compose up -d`すると、`docker/solr-init/init.sh`が、組み立て、アップロード、そのconfigsetを使うすべてのコレクションのリロード、`redmine`コレクションの作成（まだないとき）までを行う。

別のSolrCloudで使うときは、同じことを手で行う（`<ZK>`はZooKeeperの接続先）。

```bash
for name in redmine src; do
  mkdir -p /tmp/cs/${name}
  cp -r configsets/${name}/conf/. common/. /tmp/cs/${name}/
  solr zk upconfig -n ${name} -d /tmp/cs/${name} -z <ZK>
done
```

- `solr zk upconfig`は、ファイルの追加と上書きしかしない。前にあったファイルを消したときは、ZooKeeperからも`solr zk rm`で消す（`init.sh`はこれも行う）。
- 認証なしのConfigset APIではなく、`solr zk upconfig`で上げる。Configset APIで上げると「信頼されないconfigset」になる。
- コレクションは1シャード×2レプリカで作る。例：`/admin/collections?action=CREATE&name=src_12&numShards=1&replicationFactor=2&collection.configName=src`。Solrが1台なら`replicationFactor=1`にする（`redmine`も同じ。外部ソースの1台での検索も、Redmine 5.1・6.1で確かめた）。
