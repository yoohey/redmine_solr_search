# frozen_string_literal: true

require_relative '../light_helper'

# The ヴ / バ expansion (design D-21; M1 review A3, docs/experiments/search-m1 round 6)
class SpellingVariantsTest < Minitest::Test
  def expand(word)
    SolrSearch::SpellingVariants.expand(word)
  end

  def test_the_spelling_typed_comes_first
    assert_equal %w[レヴュー レビュー], expand('レヴュー')
    assert_equal %w[レビュー レヴュー], expand('レビュー')
    assert_equal %w[インタヴュー インタビュー], expand('インタヴュー')
    assert_equal %w[ヴァイオリン バイオリン], expand('ヴァイオリン')
    assert_equal %w[バイオリン ヴァイオリン], expand('バイオリン')
  end

  def test_two_character_spellings
    assert_equal %w[ヴャチェスラフ ビャチェスラフ], expand('ヴャチェスラフ')
    assert_equal %w[ヴョルド ビョルド], expand('ヴョルド')
    assert_equal %w[ビル ヴィル], expand('ビル')
  end

  def test_vu_is_not_given_to_bu_but_kept_when_typed
    assert_equal %w[ヴゥードゥー ブードゥー ヴードゥー], expand('ヴゥードゥー')
    assert_equal %w[ブードゥー ヴードゥー], expand('ブードゥー')
  end

  def test_other_forms_of_vu_are_the_nfkc_form
    assert_equal %w[ヴァイオリン バイオリン], expand('ｳﾞｧｲｵﾘﾝ')
    assert_equal %w[ヴァイオリン バイオリン], expand("ヴァイオリン")
  end

  def test_nothing_to_vary
    assert_equal %w[議事録], expand('議事録')
    assert_equal ['ｶﾞｲﾄﾞ'], expand('ｶﾞｲﾄﾞ') # as typed: no ヴ / バ row after NFKC either
  end

  def test_at_most_sixteen_and_the_spelling_typed_kept
    variants = expand('ヴァヴィヴヴェヴォヴァ')
    assert_equal SolrSearch::SpellingVariants::MAX_VARIANTS, variants.size
    assert_equal 'ヴァヴィヴヴェヴォヴァ', variants.first
    assert_equal variants.uniq, variants
    assert_equal 'バビブベボバ', variants[1]
  end

  # M7: 霞ケ関 (Tokyo Metro) and 霞ヶ関 (Tobu Tojo line) are two stations; a search finds both, the exact mode one of them
  def test_the_small_ke_after_an_ideograph_is_a_choice_and_the_typed_one_comes_first
    assert_equal %w[霞ケ関 霞ヶ関], expand('霞ケ関')
    assert_equal %w[霞ヶ関 霞ケ関], expand('霞ヶ関')
    assert_equal %w[茅ヶ崎市 茅ケ崎市], expand('茅ヶ崎市')
    assert_equal %w[三ヵ月 三カ月], expand('三ヵ月')
    assert_equal %w[三カ月 三ヵ月], expand('三カ月')
  end

  def test_ke_and_ka_not_after_an_ideograph_are_left_alone
    assert_equal %w[ケーキ], expand('ケーキ')
    assert_equal %w[ケース], expand('ケース')
    assert_equal %w[カメラ], expand('カメラ')
    assert_equal %w[ヶ], expand('ヶ')
  end

  def test_kana_and_vu_together
    assert_equal %w[霞ケ関バイオリン 霞ケ関ヴァイオリン 霞ヶ関バイオリン 霞ヶ関ヴァイオリン].sort, expand('霞ケ関バイオリン').sort
    assert_equal '霞ケ関バイオリン', expand('霞ケ関バイオリン').first
  end
end
