# frozen_string_literal: true

require_relative '../light_helper'
require 'stringio'

# The search log as CSV files in a zip (design D-45)
class LogExportTest < Minitest::Test
  X = SolrSearch::LogExport
  Log = Struct.new(:id, :created_at, :user_id, :user_login, :query, :request_path, :project_id, :page, :hit_count, :group_count,
                   :dropped_count, :took_ms, :error, :collection, :external_sources, keyword_init: true)
  Click = Struct.new(:id, :created_at, :log_id, :group_id, :rank, :kind, :title, :href, keyword_init: true)
  AT = Time.utc(2026, 10, 18, 12, 30, 5)

  def a_log(**over)
    Log.new(**{id: 5, created_at: AT, user_id: 7, user_login: 'tanaka', query: 'nginx 設定', request_path: '/solr_search?q=nginx',
               project_id: nil, page: 1, hit_count: 30, group_count: 20, dropped_count: 0, took_ms: 12, error: nil,
               collection: 'redmine', external_sources: 'src_12,src_13'}.merge(over))
  end

  def test_nothing_is_an_empty_cell_and_a_time_is_iso_8601_with_its_offset
    assert_equal '', X.cell(nil)
    assert_equal '0', X.cell(0)
    assert_equal '2026-10-18T12:30:05Z', X.cell(AT)
  end

  def test_what_could_start_a_formula_gets_a_quote_before_it
    ['=1+1', '+1', '-1', '@SUM(A1)', "\tcmd", "\rcmd", "\n=1+1", ' =1+1', "  \t@x", '＝1+1', '＋1', '－1', '＠SUM(A1)'].each {|text| assert_equal "'#{text}", X.cell(text), text.inspect }
    ['a=1', '1-1', '検索', 'nginx -apache', ' nginx', 'a =1'].each {|text| assert_equal text, X.cell(text), text.inspect }
  end

  def test_commas_quotes_and_line_breaks_come_back_as_they_were
    values = ['a,b', 'say "hi"', "two\nlines", '日本語', '']
    assert_equal values, CSV.parse_line(X.line(values))
  end

  def test_a_search_row_has_a_cell_for_each_column_and_its_clicks_in_one
    clicks = [Click.new(rank: 2, title: 'サポート #854', group_id: 'issue-854'), Click.new(rank: 1, title: nil, group_id: 'issue-287')]
    row = X.log_row(a_log, clicks)
    assert_equal X::LOG_COLUMNS.size, row.size
    assert_equal 2, row[X::LOG_COLUMNS.index('click_count')]
    assert_equal '2:サポート #854 | 1:issue-287', row[X::LOG_COLUMNS.index('opened')]
    assert_equal ['redmine', 'src_12,src_13'], row.values_at(X::LOG_COLUMNS.index('collection'), X::LOG_COLUMNS.index('external_sources'))
  end

  def test_a_search_from_before_the_collection_was_kept_has_empty_cells
    row = X.log_row(a_log(collection: nil, external_sources: nil), [])
    assert_equal [nil, nil], row.values_at(X::LOG_COLUMNS.index('collection'), X::LOG_COLUMNS.index('external_sources'))
    assert_equal '', X.line(row).then {|text| CSV.parse_line(text)[X::LOG_COLUMNS.index('collection')] }
  end

  def test_a_click_row_has_the_words_and_the_user_of_its_search
    click = Click.new(id: 9, created_at: AT, log_id: 5, group_id: 'issue-1', rank: 3, kind: 'title', title: 'T', href: '/issues/1')
    row = X.click_row(click, a_log)
    assert_equal X::CLICK_COLUMNS.size, row.size
    assert_equal ['nginx 設定', 'tanaka'], row.values_at(X::CLICK_COLUMNS.index('query'), X::CLICK_COLUMNS.index('user_login'))
    assert_equal [nil, nil], X.click_row(click, nil).values_at(3, 4) # the search was deleted: the click has no words
  end

  def test_a_csv_file_has_the_byte_order_mark_the_header_and_the_rows
    io = StringIO.new
    X.write_csv(io, %w[a b], [[1, '検索'], [2, '=x']].each)
    text = io.string
    assert text.start_with?("﻿a,b\n")
    assert_equal [%w[a b], %w[1 検索], ['2', "'=x"]], CSV.parse(text.delete_prefix("﻿"))
  end

  def test_the_zip_written_to_a_file_is_the_same_zip
    require 'tempfile'
    io = StringIO.new("﻿a\n2\n")
    Tempfile.create(['x', '.zip']) do |file|
      X.zip_to(file.path, 'search_log.csv' => "﻿id\n1\n", 'collections.csv' => io)
      contents = {}
      Zip::InputStream.open(file.path) do |zip|
        while (entry = zip.get_next_entry)
          contents[entry.name] = zip.read.force_encoding('UTF-8')
        end
      end
      assert_equal({'search_log.csv' => "﻿id\n1\n", 'collections.csv' => "﻿a\n2\n"}, contents)
    end
  end

  def test_the_body_sends_the_file_in_pieces_and_removes_it_at_the_end
    require 'tempfile'
    file = Tempfile.new(['x', '.zip'], binmode: true)
    file.write('x' * (X::TempfileBody::CHUNK * 2 + 5))
    file.flush
    path = file.path
    body = X::TempfileBody.new(file)
    assert_equal X::TempfileBody::CHUNK * 2 + 5, body.size
    sizes = []
    body.each {|chunk| sizes << chunk.bytesize }
    assert_equal [X::TempfileBody::CHUNK, X::TempfileBody::CHUNK, 5], sizes
    sizes.clear
    body.each {|chunk| sizes << chunk.bytesize } # sent again from the start
    assert_equal 3, sizes.size
    assert_equal 3, body.each.to_a.size # Rack may ask for an enumerator
    assert File.exist?(path)
    body.close
    refute File.exist?(path)
  end

  def test_the_zip_holds_the_files_and_can_be_read_back
    io = StringIO.new('from an io')
    data = X.zip('search_log.csv' => "﻿id\n1\n", 'collections.csv' => io)
    names = []
    contents = {}
    Zip::InputStream.open(StringIO.new(data)) do |zip|
      while (entry = zip.get_next_entry)
        names << entry.name
        contents[entry.name] = zip.read.force_encoding('UTF-8')
      end
    end
    assert_equal %w[search_log.csv collections.csv], names
    assert_equal "﻿id\n1\n", contents['search_log.csv']
    assert_equal 'from an io', contents['collections.csv']
  end

  def test_the_readme_names_the_columns_the_conditions_and_the_counts
    text = X.readme(exported_at: AT, filters: '期間: すべて', counts: {logs: 12, clicks: 3})
    assert text.start_with?("﻿")
    assert_includes text, '期間: すべて'
    assert_includes text, '検索 12 行、クリック 3 行'
    (X::LOG_COLUMNS + X::CLICK_COLUMNS + X::COLLECTION_COLUMNS).each {|name| assert_includes text, name }
  end
end
