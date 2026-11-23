# frozen_string_literal: true

require_relative '../light_helper'

# The address of Solr that the admin page saves, and which one is used (design D-43)
class SolrUrlTest < Minitest::Test
  U = SolrSearch::SolrUrl

  def reason(text)
    assert_raises(U::Invalid) { U.normalize(text) }.reason
  end

  def test_a_plain_address_is_kept
    assert_equal 'http://solr-lb/solr', U.normalize('http://solr-lb/solr')
    assert_equal 'https://search.example.org:8984/solr', U.normalize('https://search.example.org:8984/solr')
  end

  def test_it_is_stripped_and_loses_the_slash_at_its_end
    assert_equal 'http://solr-lb/solr', U.normalize("  http://solr-lb/solr//\n")
  end

  def test_only_http_and_https
    assert_equal :scheme, reason('ftp://solr/solr')
    assert_equal :scheme, reason('solr-lb/solr')
    assert_equal :scheme, reason('javascript:alert(1)')
  end

  def test_a_host_is_needed
    assert_equal :host, reason('http:///solr')
  end

  def test_no_user_name_or_password
    assert_equal :userinfo, reason('http://admin:secret@solr-lb/solr')
    assert_equal :userinfo, reason('http://admin@solr-lb/solr')
  end

  def test_no_query_or_fragment
    assert_equal :query, reason('http://solr-lb/solr?wt=json')
    assert_equal :query, reason('http://solr-lb/solr#x')
  end

  # The address is written into a command that an administrator copies into a shell (SchemaCheck.create_command)
  def test_what_a_shell_would_read_is_refused
    ['http://h/$(id)/solr', 'http://h/`id`/solr', 'http://h/solr;ls', 'http://h/so"lr', "http://h/so'lr", 'http://h/a&b',
     'http://h/a|b', 'http://h/a>b', 'http://h/a*', 'http://h/a\\b', 'http://h/a(b)'].each do |text|
      assert_equal :format, reason(text), text
    end
  end

  def test_the_characters_of_a_host_and_a_path_are_kept
    %w[http://localhost:8983/solr http://[::1]:8983/solr http://solr-1.example.org/a_b~c/solr http://h/a%20b/solr].each do |text|
      assert_equal text, U.normalize(text)
    end
  end

  def test_white_space_inside_and_nothing_are_refused
    assert_equal :format, reason('http://solr lb/solr')
    assert_equal :format, reason('')
    assert_equal :format, reason(nil)
  end

  def test_the_saved_address_comes_before_the_environment_variable
    assert_equal ['http://a/solr', :screen], U.resolve(saved: 'http://a/solr', env: 'http://b/solr')
  end

  def test_a_blank_saved_address_falls_back_to_the_environment_variable
    [nil, '', '  '].each {|blank| assert_equal ['http://b/solr', :env], U.resolve(saved: blank, env: 'http://b/solr') }
  end

  def test_nothing_set_is_nil
    assert_nil U.resolve(saved: '', env: nil)
    assert_nil U.resolve(saved: nil, env: ' ')
  end
end
