# frozen_string_literal: true

require_relative '../light_helper'

# How an external source shows where a document is (design D-35)
class PathMappingTest < Minitest::Test
  PM = SolrSearch::PathMapping

  def test_a_drive_of_wsl_becomes_a_windows_path
    assert_equal 'C:\\Users\\user\\ドキュメント\\fulltext\\a b.txt',
                 PM.map('/mnt/c/Users/user/ドキュメント/fulltext/a b.txt', '/mnt/c/', 'C:\\')
  end

  def test_a_folder_becomes_a_unc_path
    assert_equal '\\\\fileserver\\部門A\\議事録\\x.docx', PM.map('/data/share/議事録/x.docx', '/data/share', '\\\\fileserver\\部門A')
  end

  def test_to_without_a_backslash_or_a_drive_keeps_the_slashes
    assert_equal '/srv/docs/a/b.pdf', PM.map('/mnt/docs/a/b.pdf', '/mnt/docs', '/srv/docs/')
  end

  def test_a_trailing_separator_does_not_matter_either_side
    assert_equal 'C:\\a\\b', PM.map('/mnt/c/a/b', '/mnt/c', 'C:\\')
    assert_equal 'C:\\a\\b', PM.map('/mnt/c/a/b', '/mnt/c/', 'C:')
    assert_equal 'C:\\a\\b', PM.map('/mnt/c/a/b', '/mnt/c///', 'C:\\\\')
  end

  def test_only_at_a_boundary
    assert_equal '/mnt/cd/a', PM.map('/mnt/cd/a', '/mnt/c', 'C:\\')
    assert_equal 'C:', PM.map('/mnt/c', '/mnt/c', 'C:\\') # the folder itself
  end

  def test_a_path_that_does_not_start_with_from_is_as_it_is
    assert_equal '/home/x/a.txt', PM.map('/home/x/a.txt', '/mnt/c', 'C:\\')
  end

  def test_no_mapping_when_either_side_is_blank
    ['', nil].each do |blank|
      assert_equal '/mnt/c/a', PM.map('/mnt/c/a', blank, 'C:\\')
      assert_equal '/mnt/c/a', PM.map('/mnt/c/a', '/mnt/c', blank)
    end
    assert_equal '', PM.map(nil, '/mnt/c', 'C:\\')
  end

  def test_a_from_of_separators_only_maps_nothing
    assert_equal '/mnt/c/a', PM.map('/mnt/c/a', '/', 'C:\\')
    ['/', '///', '\\', '\\\\', '/\\'].each {|sep| refute PM.valid_from?(sep), sep }
    assert PM.valid_from?('/mnt/c/')
    assert PM.valid_from?('\\\\server\\share\\')
  end

  def test_a_path_that_is_already_windows_maps_too
    assert_equal 'Z:\\議事録\\x.docx', PM.map('\\\\fileserver\\部門A\\議事録\\x.docx', '\\\\fileserver\\部門A', 'Z:')
    assert_equal '/srv/a/議事録/x.docx', PM.map('\\\\fileserver\\部門A\\議事録\\x.docx', '\\\\fileserver\\部門A', '/srv/a')
    assert_equal '\\\\fileserver\\部門AB\\x', PM.map('\\\\fileserver\\部門AB\\x', '\\\\fileserver\\部門A', 'Z:') # a boundary
  end
end
