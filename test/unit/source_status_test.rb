# frozen_string_literal: true

require_relative '../light_helper'
require 'minitest/mock'

# Which of Solr's collections may be chosen as an external source (design D-35, D-44)
class SourceStatusTest < Minitest::Test
  Fake = Struct.new(:configsets) do
    def collection_configsets
      configsets
    end
  end

  def status(configsets)
    SolrSearch::SourceStatus.new(client: Fake.new(configsets))
  end

  CONFIGSETS = {'redmine' => 'redmine', 'redmine_prod' => 'redmine', 'src_1' => 'src', 'src_2' => 'src', 'other' => 'redmine'}.freeze

  def test_neither_the_collection_of_redmine_nor_one_named_like_its_source_is_offered
    SolrSearch.stub(:collection, 'redmine_prod') do
      names = status(CONFIGSETS).candidates([]).map(&:name)
      assert_equal %w[other src_1 src_2], names
      refute_includes names, 'redmine'
      refute_includes names, 'redmine_prod'
    end
  end

  def test_the_one_that_is_taken_is_not_offered_again
    names = status(CONFIGSETS).candidates([Struct.new(:collection).new('src_1')]).map(&:name)
    refute_includes names, 'src_1'
  end

  def test_only_the_configset_for_external_documents_may_be_chosen
    selectable = status(CONFIGSETS).candidates([]).to_h {|c| [c.name, c.selectable] }
    assert selectable['src_2']
    refute selectable['other']
  end

  def test_refusing_redmines_own_collection_and_the_name_of_its_source
    SolrSearch.stub(:collection, 'redmine_prod') do
      s = status(CONFIGSETS)
      assert_equal :redmine, s.refusal('redmine_prod')
      assert_equal :redmine, s.refusal('redmine') # M6 review (Gemini 1-2)
      assert_nil s.refusal('src_1')
      assert_equal :missing, s.refusal('nowhere')
      assert_equal :wrong_configset, s.refusal('other')
    end
  end
end
