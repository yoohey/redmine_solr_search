# frozen_string_literal: true

require_relative '../light_helper'

# The rows of collections.csv (design D-45)
class CollectionInfoTest < Minitest::Test
  DATA = {
    exported_at: Time.utc(2026, 10, 18, 12, 0, 0), solr_url: 'http://solr-lb/solr', solr_url_from: :screen,
    redmine: {name: 'redmine', configset: 'redmine', shards: 1, replicas: 2, state: :ok, problems: [], documents: 16_453,
              counts: {'issue' => [3128, 3128], 'document' => [60, 59]}},
    externals: [{label: '部門A', collection: 'src_12', configset: 'src', state: :ok, documents: 120, wrong_source: 0}]
  }.freeze

  def rows
    SolrSearch::CollectionInfo.rows(DATA)
  end

  def value(collection, key)
    rows.find {|c, _role, k, _v| c == collection && k == key }&.last
  end

  def test_every_row_has_the_four_columns
    assert rows.all? {|row| row.size == SolrSearch::LogExport::COLLECTION_COLUMNS.size }
  end

  def test_the_export_itself_and_the_solr_it_asked
    assert_equal [DATA[:exported_at], 'http://solr-lb/solr', :screen], [value('', 'exported_at'), value('', 'solr_url'), value('', 'solr_url_from')]
  end

  def test_the_collection_of_the_redmine_data
    assert_equal ['redmine', 1, 2, :ok, 16_453], %w[configset shards replicas state documents].map {|k| value('redmine', k) }
    assert_equal 'redmine', rows.find {|_c, role, k, _v| role == 'redmine' && k == 'configset' }.first
  end

  def test_the_counts_of_each_type_in_redmine_and_in_solr
    assert_equal [60, 59], [value('redmine', 'documents_redmine_document'), value('redmine', 'documents_solr_document')]
  end

  def test_an_external_source_has_its_own_rows_by_its_collection
    assert_equal ['部門A', 'src', 120, 0], %w[label configset documents wrong_source].map {|k| value('src_12', k) }
    assert(rows.select {|c, *_| c == 'src_12' }.all? {|_c, role, *_| role == 'external' })
  end

  def test_the_schema_problems_are_one_cell
    problems = DATA[:redmine].merge(state: :schema, problems: ['missing_field:group_id', 'wrong_type:project_id'])
    row = SolrSearch::CollectionInfo.rows(DATA.merge(redmine: problems)).find {|_c, _r, k, _v| k == 'schema_problems' }
    assert_equal 'missing_field:group_id; wrong_type:project_id', row.last
  end

  def test_no_source_gives_no_external_row
    refute(SolrSearch::CollectionInfo.rows(DATA.merge(externals: [])).any? {|_c, role, *_| role == 'external' })
  end
end
