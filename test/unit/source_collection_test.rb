# frozen_string_literal: true

require_relative '../light_helper'
require 'minitest/mock'

# Which collections may be external index sources (design D-35): Solr's names, never Redmine's own collection
class SourceCollectionTest < Minitest::Test
  def test_solr_names
    %w[src_12 minutes-2026 dept.a A_b-c.9].each {|name| assert SolrSearch.external_collection?(name), name }
  end

  def test_not_a_solr_name
    ['-src', 'src 12', "src_12'", 'src_12,redmine', 'src_12 OR source:redmine', '', '部門A'].each do |name|
      refute SolrSearch.external_collection?(name), name
    end
    refute SolrSearch.external_collection?(nil)
    %w[. .. ...].each {|name| refute SolrSearch.external_collection?(name), name } # a path of its own in an address (M6 review 20)
    assert SolrSearch.external_collection?('a.b')
  end

  def test_never_redmine
    refute SolrSearch.external_collection?(SolrSearch::COLLECTION)
  end

  # The collection of Redmine's data may be named otherwise (D-44), but its documents' source stays "redmine": a collection
  # of that name must not be taken as external either (M6 review 1)
  def test_never_the_source_of_redmines_documents_even_when_the_collection_is_named_otherwise
    SolrSearch.stub(:collection, 'redmine_prod') do
      refute SolrSearch.external_collection?('redmine_prod')
      refute SolrSearch.external_collection?(SolrSearch::SOURCE)
      assert SolrSearch.external_collection?('src_12')
    end
  end
end
