# frozen_string_literal: true

require_relative '../light_helper'
require 'tmpdir'
require 'fileutils'
require File.join(LIB, 'solr_search', 'golden_runner')

# Which data set and which sets the golden rake takes (O-58: the public repository has no ja-cf, and ja-basic has no
# golden.yml). The searches and the record need Redmine and are not tried here.
class GoldenRunnerTest < Minitest::Test
  Runner = SolrSearch::GoldenRunner

  def seed(datasets)
    Dir.mktmpdir do |dir|
      datasets.each do |name, files|
        FileUtils.mkdir_p(File.join(dir, name, 'expected'))
        files.each {|file| File.write(File.join(dir, name, 'expected', file), "[]\n") }
      end
      yield dir
    end
  end

  def test_ja_cf_stays_the_default_where_it_is
    seed('ja-cf' => %w[expected.yml golden.yml], 'ja-basic' => %w[expected.yml]) do |dir|
      assert_equal 'ja-cf', Runner.default_dataset(seed_dir: dir)
      assert_equal %w[coverage ranking], Runner.new(dataset: 'ja-cf', seed_dir: dir).available_sets
    end
  end

  def test_ja_basic_where_ja_cf_is_not
    seed('ja-basic' => %w[expected.yml]) do |dir|
      assert_equal 'ja-basic', Runner.default_dataset(seed_dir: dir)
      assert_equal %w[coverage], Runner.new(dataset: 'ja-basic', seed_dir: dir).available_sets
    end
  end

  def test_a_missing_file_is_said_and_not_a_crash
    seed({}) do |dir|
      runner = Runner.new(dataset: 'nothing', seed_dir: dir)
      assert_empty runner.available_sets
      %w[coverage ranking].each do |set|
        error = assert_raises(SolrSearch::Golden::Invalid) { runner.public_send(set) }
        assert_includes error.message, 'nothing'
        assert_includes error.message, Runner::FILES[set]
      end
    end
  end
end
