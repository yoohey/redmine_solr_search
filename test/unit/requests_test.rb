# frozen_string_literal: true

require_relative '../light_helper'

# What the admin page may ask for (design D-42): the types of a reindex request
class RequestsTest < Minitest::Test
  ALLOWED = %w[issue journal wiki_page document].freeze

  def normalize(types)
    SolrSearch::Requests.normalize_types(types, ALLOWED)
  end

  def test_the_chosen_types_come_back_in_the_order_of_the_allowed_ones
    assert_equal %w[issue wiki_page], normalize(%w[wiki_page issue])
  end

  def test_a_type_chosen_twice_is_one
    assert_equal %w[journal], normalize(%w[journal journal])
  end

  def test_nothing_chosen_is_refused
    [[], nil, ['', '']].each do |none|
      error = assert_raises(SolrSearch::Requests::Invalid) { normalize(none) }
      assert_equal :no_type, error.reason
    end
  end

  def test_an_unknown_type_is_refused_and_named
    error = assert_raises(SolrSearch::Requests::Invalid) { normalize(%w[issue nonsense]) }
    assert_includes error.message, 'nonsense'
    assert_equal :unknown_type, error.reason
  end

  def test_a_type_that_exists_but_is_not_offered_is_refused
    assert_raises(SolrSearch::Requests::Invalid) { normalize(%w[attachment]) }
  end

  def test_a_single_string_is_accepted
    assert_equal %w[issue], normalize('issue')
  end
end
