# frozen_string_literal: true

require_relative '../light_helper'

# The start of a snippet is cut away when its first mark is out of sight (M7; a station at the 261st character of a table)
class SnippetTest < Minitest::Test
  PRE = SolrSearch::Searcher::HL_PRE
  POST = SolrSearch::Searcher::HL_POST

  def cut(text)
    SolrSearch::Snippet.from_first_mark(text)
  end

  def test_a_mark_in_sight_leaves_the_text_as_it_is
    text = "#{'あ' * 40}#{PRE}鶴ヶ島#{POST}#{'い' * 100}"
    assert_equal text, cut(text)
  end

  def test_a_text_without_a_mark_is_left_as_it_is
    text = 'あ' * 300
    assert_equal text, cut(text)
  end

  def test_a_mark_out_of_sight_brings_the_start_to_it_with_an_ellipsis
    text = "#{'あ' * 261}#{PRE}鶴ヶ島#{POST}#{'い' * 100}"
    shown = cut(text)
    assert shown.start_with?("…#{'あ' * SolrSearch::Snippet::LEAD}#{PRE}鶴ヶ島#{POST}")
    assert_operator shown.index(PRE), :<=, SolrSearch::Snippet::VISIBLE
  end

  def test_the_other_marks_are_kept
    text = "#{'あ' * 200}#{PRE}東京#{POST}う#{PRE}新宿#{POST}"
    shown = cut(text)
    assert_equal 2, shown.scan(PRE).size
    assert_equal 2, shown.scan(POST).size
  end

  def test_the_boundary_is_in_sight
    text = "#{'あ' * SolrSearch::Snippet::VISIBLE}#{PRE}語#{POST}"
    assert_equal text, cut(text)
  end
end
