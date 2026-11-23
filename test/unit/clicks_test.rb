# frozen_string_literal: true

require_relative '../light_helper'

# The row that a click on a result leaves (design D-45)
class ClicksTest < Minitest::Test
  def attrs(**over)
    SolrSearch::Clicks.attributes(**{group: 'issue-12', rank: '3', kind: 'title', title: " Nginx の設定 \n", href: '/issues/12'}.merge(over))
  end

  def test_a_click_on_a_title
    assert_equal({group_id: 'issue-12', rank: 3, kind: 'title', title: 'Nginx の設定', href: '/issues/12'}, attrs)
  end

  def test_an_unknown_kind_is_other
    assert_equal 'other', attrs(kind: 'whatever')[:kind]
    assert_equal 'other', attrs(kind: nil)[:kind]
    SolrSearch::Clicks::KINDS.each {|kind| assert_equal kind, attrs(kind: kind)[:kind] }
  end

  def test_a_rank_that_is_no_place_in_a_list_is_nil
    ['', 'abc', '0', '-1', '1001', '3.5', nil].each {|bad| assert_nil attrs(rank: bad)[:rank], bad.inspect }
    assert_equal 1000, attrs(rank: '1000')[:rank]
  end

  def test_empty_title_and_href_are_nil
    a = attrs(title: '  ', href: '')
    assert_nil a[:title]
    assert_nil a[:href]
  end

  def test_long_values_are_cut
    a = attrs(group: 'g' * 900, title: 't' * 900, href: 'h' * 5000)
    assert_equal [SolrSearch::Clicks::GROUP_MAX, SolrSearch::Clicks::TITLE_MAX, SolrSearch::Clicks::HREF_MAX],
                 [a[:group_id].size, a[:title].size, a[:href].size]
  end

  Log = Struct.new(:click_token, :user_id, :created_at)
  NOW = Time.utc(2026, 10, 18, 12, 0, 0)
  TOKEN = 'a' * 32

  def accepted(log: Log.new(TOKEN, 7, NOW - 60), mine: 7, token: TOKEN)
    SolrSearch::Clicks.accepted?(log, mine: mine, token: token, now: NOW)
  end

  def test_a_click_with_the_mark_of_its_search_from_its_user_is_taken
    assert accepted
  end

  def test_nobody_logged_in_is_a_user_too_but_only_with_the_mark
    assert accepted(log: Log.new(TOKEN, nil, NOW - 60), mine: nil)
    refute accepted(log: Log.new(TOKEN, nil, NOW - 60), mine: nil, token: 'b' * 32) # another one who is not logged in, guessing the number
    refute accepted(log: Log.new(TOKEN, nil, NOW - 60), mine: nil, token: nil)
  end

  def test_the_mark_must_be_the_same
    refute accepted(token: 'b' * 32)
    refute accepted(token: TOKEN[0, 31])
    refute accepted(token: '')
    refute accepted(token: nil)
    refute accepted(token: [TOKEN])
  end

  def test_a_search_without_a_mark_takes_no_clicks
    refute accepted(log: Log.new(nil, 7, NOW - 60), token: '')
    refute accepted(log: Log.new('', 7, NOW - 60), token: '')
  end

  def test_another_user_or_no_search_is_refused
    refute accepted(mine: 8)
    refute accepted(mine: nil)
    refute accepted(log: nil)
  end

  def test_after_a_day_it_is_refused
    assert accepted(log: Log.new(TOKEN, 7, NOW - 23 * 3600))
    refute accepted(log: Log.new(TOKEN, 7, NOW - 25 * 3600))
  end
end
