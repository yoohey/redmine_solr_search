# frozen_string_literal: true

require_relative '../light_helper'

# The query expansion dictionary (design D-53, Q-27)
class QueryDictionaryTest < Minitest::Test
  D = SolrSearch::QueryDictionary

  def dict(text)
    D.build(text)
  end

  def reasons(text)
    D.parse(text).problems.map {|p| [p.line, p.reason] }
  end

  def test_a_word_of_a_group_becomes_the_typed_word_and_the_others
    d = dict("シングルサインオン,SSO,統合認証\n")
    assert_equal [%w[SSO シングルサインオン 統合認証]], d.expand(%w[SSO])
    assert_equal [%w[シングルサインオン SSO 統合認証]], d.expand(%w[シングルサインオン])
  end

  def test_a_word_that_is_not_in_the_dictionary_stays_alone_in_its_place
    d = dict("SSO,シングルサインオン\n")
    assert_equal [%w[障害], %w[SSO シングルサインオン], %w[対応]], d.expand(%w[障害 SSO 対応])
    assert_equal [%w[a]], D.empty.expand(%w[a])
  end

  def test_the_whole_word_only
    d = dict("PC,パソコン\n")
    assert_equal [%w[PC管理]], d.expand(%w[PC管理])
  end

  def test_case_width_and_spaces_are_ignored_in_the_match_but_the_typed_word_is_kept
    d = dict("PC,パソコン\n")
    assert_equal [%w[pc パソコン]], d.expand(%w[pc])
    assert_equal [%w[ＰＣ パソコン]], d.expand(%w[ＰＣ])
    assert_equal [%w[Ｐｃ パソコン]], d.expand(%w[Ｐｃ])
  end

  def test_a_term_with_a_space_matches_words_that_stand_together_longest_first
    d = dict("シングル サインオン,SSO\nシングル,single\n")
    assert_equal [['シングル サインオン', 'SSO'], %w[設定]], d.expand(%w[シングル サインオン 設定])
    assert_equal [%w[シングル single], %w[設定]], d.expand(%w[シングル 設定])
    assert_equal [['シングル サインオン', 'SSO']], d.expand(['シングル', 'サインオン'])
  end

  def test_a_term_in_two_lines_takes_both_but_the_groups_are_not_chained
    d = dict("A,B\nB,C\n")
    assert_equal [%w[B A C]], d.expand(%w[B])
    assert_equal [%w[A B]], d.expand(%w[A])
    assert_equal [%w[C B]], d.expand(%w[C])
  end

  def test_the_text_comments_blanks_separators_and_a_duplicate_term
    text = "# a comment\n\n旧称，新称、別名,新称\n  略語 , 正式名称  \n"
    assert_equal [%w[旧称 新称 別名], %w[略語 正式名称]], D.parse(text).groups
    assert_empty D.parse(text).problems
  end

  def test_the_terms_are_kept_in_nfkc_form
    assert_equal [%w[PC1 パソコン]], D.parse("ＰＣ１,ﾊﾟｿｺﾝ\n").groups
  end

  def test_what_is_refused_with_the_line
    assert_equal [[1, :too_few], [3, :too_few]], reasons("a\nb,c\n,\n")
    assert_equal [[1, :too_many_terms]], reasons((1..9).map {|i| "t#{i}" }.join(',') + "\n")
    assert_equal [[1, :term_too_many_words]], reasons("a b c d e,x\n")
    assert_equal [[1, :term_too_long]], reasons("#{'あ' * 101},x\n")
    assert_equal [[1, :too_few]], reasons("同じ,同じ\n") # the same term twice is one term
    assert_equal [[0, :too_many_lines]], reasons("a,b\n" * 2_001)
    assert_includes reasons("#{'x' * (D::MAX_BYTES + 1)}\n"), [0, :too_big]
  end

  def test_a_line_with_a_problem_is_left_out_but_the_rest_is_used
    d = dict("alone\nSSO,シングルサインオン\n")
    assert_equal [%w[SSO シングルサインオン]], d.expand(%w[SSO])
    assert_equal [%w[alone]], d.expand(%w[alone])
  end

  def test_empty
    assert D.empty.empty?
    assert dict("# nothing\n").empty?
    assert dict(nil).empty?
  end

  def warnings(text)
    D.warnings(text).map {|w| [w.line, w.reason, w.detail] }
  end

  def test_warnings_for_a_separator_that_looks_like_one
    assert_equal [[1, :other_separator, ';']], warnings("SSO;シングル サインオン\n")
    assert_equal [[1, :other_separator, '→']], warnings("旧称→新称\n")
    assert_equal [[1, :other_separator, 'Tab']], warnings("旧称\t新称\n")
    assert_empty warnings("旧称,新称\n")
  end

  def test_warnings_for_a_term_twice_and_a_term_in_several_lines
    assert_equal [[1, :duplicate_term, 'PC']], warnings("PC,ＰＣ,パソコン\n")
    assert_equal [[1, :shared_term, 'B (1, 2)']], warnings("A,B\nB,C\n")
  end

  def test_no_warnings_for_comments_and_blank_lines
    assert_empty warnings("# a;b\n\nA,B\n")
  end

  def test_the_dictionary_that_the_plugin_starts_with_has_no_unusable_line
    text = File.read(File.expand_path('../../config/default_synonyms.txt', __dir__), encoding: 'UTF-8')
    parsed = D.parse(text)
    assert_empty parsed.problems
    assert_operator parsed.groups.size, :>=, 5
    assert_empty D.warnings(text)
  end
end
