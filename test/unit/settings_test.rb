# frozen_string_literal: true

require_relative '../light_helper'

# The plugin's settings (SolrSearch::Settings): the one way that they are written, and what the settings screen sends back. Redmine's
# Setting and its plugin registry are stood in for (the light tests do not load Redmine).
class SettingsTest < Minitest::Test
  DEFAULTS = {'show_solr_request' => '0', 'expand_spelling_variants' => '1', 'highlight_style' => 'default style', 'solr_url' => '',
              'redmine_collection' => 'redmine', 'tika_url' => '', 'reranker_url' => '', 'reranker_format' => 'tei', 'reranker_model' => '',
              'reranker_timeout' => '3', 'reranker_docs' => '40', 'reranker_chars' => '400', 'max_words' => '10', 'per_page' => '50'}.freeze

  # Setting.plugin_redmine_solr_search: a Hash, as Redmine keeps it
  class FakeSetting
    class << self
      attr_accessor :value
    end

    def self.plugin_redmine_solr_search
      value
    end

    def self.plugin_redmine_solr_search=(hash)
      self.value = hash
    end
  end
  Plugin = Struct.new(:settings)

  def setup
    @had_setting = Object.const_defined?(:Setting)
    Object.const_set(:Setting, FakeSetting) unless @had_setting
    @redmine = Object.const_defined?(:Redmine)
    Object.const_set(:Redmine, Module.new) unless @redmine
    @plugin_class = Redmine.const_defined?(:Plugin)
    plugin = Class.new { define_singleton_method(:find) {|_| Plugin.new({default: DEFAULTS}) } }
    Redmine.const_set(:Plugin, plugin) unless @plugin_class
    FakeSetting.value = {}
    @logged = []
    @log = SolrSearch.method(:log)
    logged = @logged
    SolrSearch.define_singleton_method(:log) {|level, message| logged << [level, message] }
  end

  def teardown
    SolrSearch.define_singleton_method(:log, @log)
    Redmine.send(:remove_const, :Plugin) unless @plugin_class
    Object.send(:remove_const, :Redmine) unless @redmine
    Object.send(:remove_const, :Setting) unless @had_setting
  end

  def test_update_merges_into_what_is_stored_and_keeps_the_rest
    FakeSetting.value = {'max_words' => '7', 'solr_url' => 'http://old'}
    SolrSearch::Settings.update({'solr_url' => 'http://new', 'reranker_url' => 'http://r'})
    assert_equal({'max_words' => '7', 'solr_url' => 'http://new', 'reranker_url' => 'http://r'}, FakeSetting.value)
  end

  def test_update_logs_each_change_and_only_the_changes
    FakeSetting.value = {'solr_url' => 'http://a', 'reranker_docs' => '40'}
    SolrSearch::Settings.update({solr_url: 'http://b', 'reranker_docs' => '40'}, by: 'admin')
    assert_equal [[:info, 'solr_url changed by admin: "http://a" -> "http://b"']], @logged
  end

  def test_update_when_nothing_was_stored
    FakeSetting.value = nil
    SolrSearch::Settings.update({'max_words' => '3'})
    assert_equal({'max_words' => '3'}, FakeSetting.value)
  end

  def test_per_page_is_kept_in_its_range
    {'25' => 25, '1' => 10, '5000' => 100, 'x' => 50, '' => 50, nil => 50}.each do |saved, want|
      FakeSetting.value = {'per_page' => saved}
      assert_equal want, SolrSearch::Settings.per_page, saved.inspect
    end
  end

  def test_what_the_settings_screen_sends_back
    FakeSetting.value = {'redmine_collection' => '', 'show_solr_request' => '1', 'reranker_url' => 'http://r'}
    values = SolrSearch::Settings.admin_page_values
    assert_equal SolrSearch::Settings::ADMIN_PAGE_KEYS - %w[highlight_style], values.keys, 'the style only when it was saved'
    assert_equal '', values['redmine_collection'], 'the collection as it is kept: empty is not written as the default'
    assert_equal '1', values['show_solr_request']
    assert_equal '1', values['expand_spelling_variants'], 'a setting never saved is sent as its default'
    assert_equal 'http://r', values['reranker_url']
    FakeSetting.value = {'highlight_style' => ''}
    assert_equal '', SolrSearch::Settings.admin_page_values['highlight_style'], 'a saved empty style is "no style"'
  end

  def test_every_key_of_the_admin_page_has_a_default
    assert_empty SolrSearch::Settings::ADMIN_PAGE_KEYS - DEFAULTS.keys
  end

  # The Tika address (design D-61): the one saved on the admin page, else TIKA_URL, else the default
  def test_tika_address_takes_the_saved_one_first
    before = ENV['TIKA_URL']
    ENV['TIKA_URL'] = 'http://env-tika:9998'
    FakeSetting.value = {'tika_url' => 'http://127.0.0.1:9998'}
    assert_equal ['http://127.0.0.1:9998', :screen], SolrSearch::Settings.tika_address
    FakeSetting.value = {'tika_url' => ''}
    assert_equal ['http://env-tika:9998', :env], SolrSearch::Settings.tika_address
    ENV.delete('TIKA_URL')
    assert_equal ['http://tika:9998', :default], SolrSearch::Settings.tika_address
  ensure
    before ? ENV['TIKA_URL'] = before : ENV.delete('TIKA_URL')
  end
end
