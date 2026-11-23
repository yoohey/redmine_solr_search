# frozen_string_literal: true

require_relative '../light_helper'

# Design D-64: every collection that is searched together scores with its own term statistics (LocalStatsCache).
# ExactStatsCache (D-48) took the docCount of one collection, a different one at each request (SOLR-15319), so the
# order changed from one search to the next; a configset that kept it would bring that back, without any error.
class ConfigsetStatsCacheTest < Minitest::Test
  CONFIGSETS = File.expand_path('../../solr/configsets', __dir__)

  def test_every_configset_has_local_stats_cache
    files = Dir[File.join(CONFIGSETS, '*', 'conf', 'solrconfig.xml')]
    assert_operator files.size, :>=, 2
    files.each do |file|
      text = File.read(file)
      assert_match(%r{^\s*<statsCache class="org\.apache\.solr\.search\.stats\.LocalStatsCache"\s*/>}, text, file)
      refute_match(/ExactStatsCache/, text.gsub(/<!--.*?-->/m, ''), file)
    end
  end
end
