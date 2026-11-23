# frozen_string_literal: true

require 'csv'
require 'zip'

module SolrSearch
  # The search log as files for the people who work on it by hand (design D-45): CSV in UTF-8 with a byte order mark, three
  # of them and a README in one zip, to be read by Power Query and the like. The column names are fixed English names, so
  # that a query that reads them does not break. Pure, apart from the files it is given: light tests check it.
  module LogExport
    BOM = "﻿"

    LOG_COLUMNS = %w[id created_at user_id user_login query request_path project_id page hit_count group_count dropped_count
                     took_ms error collection external_sources click_count opened].freeze
    CLICK_COLUMNS = %w[id created_at log_id query user_login group_id rank kind title href].freeze
    COLLECTION_COLUMNS = %w[collection role key value].freeze

    module_function

    # The text of a cell: nothing is empty, a time is ISO 8601 with its offset. What begins with a character that Excel reads
    # as the start of a formula (= + - @, also the full-width ones), or begins with a control character (a line feed, a tab ...) or with spaces before one of them (Gemini, Sec-2), gets a ' before it, so that it stays text when the file is opened in Excel (spreadsheet formula injection: a
    # search is typed by anyone, the file is opened by an administrator; M6 review 18).
    def cell(value)
      text = value.respond_to?(:iso8601) ? value.in_time_zone.iso8601 : value.to_s
      text.match?(/\A(?:[[:cntrl:]]|[[:space:]]*[=+\-@＝＋－＠])/) ? "'#{text}" : text
    end

    def line(values)
      CSV.generate_line(values.map {|value| cell(value) })
    end

    # One search, as a row: its clicks as "place:title" joined by " | "
    def log_row(log, clicks)
      [log.id, log.created_at, log.user_id, log.user_login, log.query, log.request_path, log.project_id, log.page, log.hit_count,
       log.group_count, log.dropped_count, log.took_ms, log.error, log.collection, log.external_sources, clicks.size,
       clicks.map {|click| "#{click.rank}:#{click.title.presence || click.group_id}" }.join(' | ')]
    end

    # One click, as a row, with what it follows (the words and the user of its search)
    def click_row(click, log)
      [click.id, click.created_at, click.log_id, log&.query, log&.user_login, click.group_id, click.rank, click.kind, click.title, click.href]
    end

    # Writes a CSV file (the byte order mark, the header, the rows) to io; rows: anything that yields arrays, one by one,
    # so that a log of years is not held in memory
    def write_csv(io, columns, rows)
      io.write(BOM)
      io.write(line(columns))
      rows.each {|values| io.write(line(values)) }
      io.flush
    end

    # {file name => String or an IO} as a zip, in a string. An IO is read from its start. (Holds the whole zip in memory: for
    # what is small. The download is made with zip_to.)
    def zip(files)
      Zip::OutputStream.write_buffer {|out| put_files(out, files) }.string
    end

    # The same, written to a file on disk, so that a log of any size is not held in memory (M6 review 11)
    def zip_to(path, files)
      Zip::OutputStream.open(path) {|out| put_files(out, files) }
      path
    end

    def put_files(out, files)
      files.each do |name, content|
        out.put_next_entry(name)
        if content.respond_to?(:read)
          content.rewind
          IO.copy_stream(content, out)
        else
          out.write(content)
        end
      end
    end
    private_class_method :put_files

    # A response body that sends a file in pieces and removes it when the response is over (Rack calls close). A temporary file
    # that is removed after the action has returned would be gone before it is sent; one that is left to the garbage
    # collector may be removed in the middle of it.
    class TempfileBody
      CHUNK = 64 * 1024

      def initialize(tempfile)
        @tempfile = tempfile
      end

      def size
        @tempfile.size
      end

      def each
        return to_enum(:each) unless block_given?

        @tempfile.rewind
        while (chunk = @tempfile.read(CHUNK))
          yield chunk
        end
      end

      def close
        @tempfile.close!
      end
    end

    # The file that says what the others are: the columns, the conditions of the export, and the cautions
    def readme(exported_at:, filters:, counts:)
      <<~TEXT
        #{BOM}検索ログの書き出し（redmine_solr_search）
        書き出した時刻: #{exported_at.in_time_zone.iso8601}
        絞り込みの条件: #{filters}
        件数: 検索 #{counts[:logs]} 行、クリック #{counts[:clicks]} 行

        ファイルはどれも CSV（UTF-8、先頭に BOM）です。Excel で開くか、Power Query（データ > テキストまたは CSV から）で読みます。
        列の名前は、変わらない英語の名前です。日時は、タイムゾーンつきの ISO 8601 です。空は、その値がないことです。
        先頭が = + - @ の文字列は、Excel で開いたとき式にならないよう、先頭に ' を付けてあります（Power Query では、必要なら Text.TrimStart で外せます）。
        検索語と利用者が入っています。取り扱いに気を付けてください。

        search_log.csv（1検索1行。検索画面で、Solr に問い合わせた検索だけ）
          #{LOG_COLUMNS.join(', ')}
          id: ログの行の番号 / created_at: 検索した日時 / user_id, user_login: 利用者（その時のログイン名。ログインなしは空）
          query: 検索語 / request_path: リクエスト（パスと検索条件） / project_id: プロジェクトから開いた検索のプロジェクト
          page: 結果のページ（2以降は、同じ検索の続き。検索の件数としては、page が 1 の行を数える）
          hit_count: Solr が数えた件数（失敗のときは空。0 は結果なし） / group_count: グループ数
          dropped_count: Solr が返したグループのうち、Redmine の確認で出さなかった数（ふつう 0）
          took_ms: かかった時間（ミリ秒） / error: 失敗の理由 / collection: 検索したコレクション / external_sources: 一緒に検索した外部ソースのコレクション（コンマ区切り）
          click_count: 結果から開かれた数 / opened: 開いたもの（「順位:タイトル」を " | " でつなぐ）
          コレクションと外部ソースが空の行は、それを残す前の検索です。

        search_clicks.csv（結果から開いたもの。1クリック1行）
          #{CLICK_COLUMNS.join(', ')}
          log_id: search_log.csv の id / query, user_login: その検索の検索語と利用者 / group_id: 開いたもの（issue-12 など）
          rank: 結果の中の順位（1から） / kind: title, note, attachment, more, other / title: リンクの文字 / href: リンクの先

        collections.csv（書き出した時点の、コレクションの様子。縦持ち）
          #{COLLECTION_COLUMNS.join(', ')}
          role: redmine（Redmine のデータ）、external（外部ソース）、export（この書き出し）
      TEXT
    end
  end
end
