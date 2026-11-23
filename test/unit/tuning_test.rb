# frozen_string_literal: true

require_relative '../light_helper'

# The tuning of the order of the results (design D-51, Q-34): the weights written for Solr, and what may be saved
class TuningTest < Minitest::Test
  T = SolrSearch::Tuning

  def defaults
    T.normalize(nil)
  end

  def with(**changes)
    t = T.normalize(nil)
    changes.each do |path, value|
      keys = path.to_s.split('.')
      keys.size == 1 ? t[keys[0]] = value : t[keys[0]][keys[1]] = value
    end
    t
  end

  def test_a_search_never_tuned_sends_what_it_always_sent
    assert_equal SolrSearch::Searcher::QF, T.qf(defaults)
    assert_empty T.params(defaults)
    assert_empty T.params(defaults, exact: true)
    assert_empty T.validate(defaults)
  end

  def test_normalize_fills_in_what_is_missing_and_drops_what_is_not_known
    got = T.normalize('qf' => {'title_ja' => '5', 'nonsense' => '1'}, 'types' => {'issue' => 2}, 'unknown' => 1, 'pf2' => 'x')
    assert_equal 5.0, got['qf']['title_ja']
    assert_equal 2.0, got['qf']['content_ja'] # the default
    refute got['qf'].key?('nonsense')
    assert_equal 2.0, got['types']['issue']
    assert_equal 0.0, got['pf2'] # not a number: the default
    refute got.key?('unknown')
    assert_equal defaults, T.normalize('garbage')
  end

  def test_the_weights_of_the_fields
    assert_equal 'title_ja^5 content_ja^2 title^0.5 content', T.qf(with('qf.title_ja': 5.0, 'qf.title': 0.5))
    assert_equal 'title_ja^3 title content', T.qf(with('qf.content_ja': 0.0)) # a weight of zero leaves the field out
  end

  def test_a_bonus_for_the_words_that_stand_together
    assert_equal({pf2: 'title_ja^2 content_ja^2'}, T.params(with(pf2: 2.0)))
    assert_empty T.params(with(pf2: 2.0), exact: true) # the n-gram search has no such bonus
  end

  def test_the_multipliers_of_types_and_sources
    one = T.params(with('types.external': 0.5))
    assert_equal({boost: "if(query({!v='type:(file)'}),0.5,1)"}, one)
    two = T.params(with('types.issue': 2.0, 'types.attachment': 0.8)).fetch(:boost)
    assert_equal "product(if(query({!v='type:(issue OR journal)'}),2,1),if(query({!v='type:(attachment)'}),0.8,1))", two
    t = with('types.external': 1.0)
    t['sources'] = {'src_3' => 1.5, 'src_4' => 1.0}
    assert_equal({boost: "if(query({!v='source:src_3'}),1.5,1)"}, T.params(t))
  end

  def test_how_new
    boost = T.params(with('recency.strength': 1.0, 'recency.half_life_days': 100.0)).fetch(:boost)
    assert_equal 'sum(1,product(1,recip(ms(NOW/DAY,updated_at),1.1574e-10,1,1)))', boost # 1 / (100 days in ms)
    refute_includes T.params(with('recency.strength': 0.0)).to_s, 'recip'
  end

  def test_everything_together
    t = with('types.external': 0.5, 'recency.strength': 0.5)
    boost = T.params(t).fetch(:boost)
    assert boost.start_with?('product(if(query({!v=\'type:(file)\'}),0.5,1),sum(1,product(0.5,recip(')
  end

  def test_what_may_be_saved
    assert_empty T.validate(with('qf.title_ja': 20.0, 'types.issue': 10.0, 'recency.half_life_days': 7.0))
    errors = T.validate(with('qf.title_ja': 21.0, 'types.issue': 0.05, pf2: -1.0, 'recency.strength': 6.0, 'recency.half_life_days': 1.0))
    assert_equal %w[pf2 qf.title_ja recency.half_life_days recency.strength types.issue], errors.keys.sort
    none = with('qf.title_ja': 0.0, 'qf.content_ja': 0.0, 'qf.title': 0.0, 'qf.content': 0.0)
    assert_equal({'qf' => :none_positive}, T.validate(none)) # a query with no field to look in
    nan = with(pf2: Float::NAN)
    assert_includes T.validate(nan).keys, 'pf2'
    t = defaults
    t['sources'] = {'src_1' => 11.0}
    assert_equal ['sources.src_1'], T.validate(t).keys
  end

  def test_sources_are_only_collections_of_sources
    got = T.normalize('sources' => {'src_9' => '2', 'redmine' => '3', "src_1'}" => '4', 'src_a b' => '2'})
    assert_equal({'src_9' => 2.0}, got['sources'])
  end

  def test_parse_tells_what_is_not_a_number
    parsed, bad = T.parse({'qf' => {'title_ja' => '4', 'content_ja' => 'abc'}, 'pf2' => '', 'sources' => {'src_2' => '1.5'}})
    assert_equal 4.0, parsed['qf']['title_ja']
    assert_equal 2.0, parsed['qf']['content_ja'] # kept as the default, and said to be bad
    assert_equal ['qf.content_ja'], bad.keys
    assert_equal 0.0, parsed['pf2'] # blank is not given
    assert_equal({'src_2' => 1.5}, parsed['sources'])
  end

  def test_what_changed_between_two_tunings
    after = with('qf.title_ja': 5.0, 'types.external': 0.5)
    after['sources'] = {'src_3' => 2.0}
    assert_equal [['qf.title_ja', 3.0, 5.0], ['types.external', 1.0, 0.5], ['sources.src_3', nil, 2.0]], T.changes(defaults, after)
    assert_empty T.changes(defaults, defaults)
  end
end

