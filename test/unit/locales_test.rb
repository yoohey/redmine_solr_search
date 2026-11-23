# frozen_string_literal: true

require_relative '../light_helper'
require 'yaml'

# The two translation files: both parse (a stray double quote inside a quoted text breaks a whole file, and the screens
# of the other language with it), and have the same keys
class LocalesTest < Minitest::Test
  DIR = File.expand_path('../../config/locales', __dir__)

  def load(lang)
    YAML.load_file(File.join(DIR, "#{lang}.yml")).fetch(lang)
  end

  def test_both_files_parse_and_have_the_same_keys
    ja = load('ja')
    en = load('en')
    assert_empty ja.keys - en.keys, 'in ja.yml only'
    assert_empty en.keys - ja.keys, 'in en.yml only'
  end

  # the %{name} of a text must be in its translation too, or the screen shows a literal "%{name}" / raises
  def test_the_same_placeholders_in_both
    ja = load('ja')
    load('en').each do |key, text|
      assert_equal ja[key].to_s.scan(/%\{(\w+)\}/).flatten.sort, text.to_s.scan(/%\{(\w+)\}/).flatten.sort, key
    end
  end
end
