# frozen_string_literal: true

require_relative '../light_helper'

# Who may open the global search (design D-34; review of M3 step 4)
class GlobalSearchAccessTest < Minitest::Test
  User = Struct.new(:logged, :admin, keyword_init: true) do
    def logged?; logged; end
    def admin?; admin; end
  end
  ANONYMOUS = User.new(logged: false, admin: false)
  MEMBER = User.new(logged: true, admin: false)
  ADMIN = User.new(logged: true, admin: true)

  def allowed?(user, access, permission: false)
    asked = false
    result = SolrSearch.global_search_allowed?(user, access: access) { asked = true; permission }
    [result, asked]
  end

  def test_all_lets_everyone_in_without_asking
    [ANONYMOUS, MEMBER, ADMIN].each {|u| assert_equal [true, false], allowed?(u, 'all')}
  end

  def test_logged_keeps_the_anonymous_out
    assert_equal [false, false], allowed?(ANONYMOUS, 'logged')
    assert_equal [true, false], allowed?(MEMBER, 'logged')
  end

  def test_with_permission_asks_only_for_users_who_are_not_admin
    assert_equal [true, false], allowed?(ADMIN, 'with_permission')
    assert_equal [false, true], allowed?(MEMBER, 'with_permission', permission: false)
    assert_equal [true, true], allowed?(MEMBER, 'with_permission', permission: true)
    assert_equal [false, true], allowed?(ANONYMOUS, 'with_permission', permission: false)
  end

  def test_an_unknown_value_is_the_strictest
    assert_equal 'with_permission', SolrSearch.global_search_access('allow-all')
    assert_equal 'with_permission', SolrSearch.global_search_access(nil)
    %w[all logged with_permission].each {|v| assert_equal v, SolrSearch.global_search_access(v)}
    assert_equal [false, true], allowed?(MEMBER, SolrSearch.global_search_access('typo'))
  end
end
