# frozen_string_literal: true

require_relative '../light_helper'

# The link format of an external source (design D-35)
class LinkPatternTest < Minitest::Test
  LP = SolrSearch::LinkPattern

  def test_http_and_https_with_a_host_of_their_own_are_valid
    ['https://intranet.example/files/%path%', 'http://intranet/%id%', 'https://h:8080/x', 'HTTPS://H/x', 'https://h',
     'https://h?path=%path%', 'https://h#%title%'].each {|p| assert LP.valid?(p), p}
  end

  def test_other_things_are_not
    ['', nil, 'file://fs/%path%', 'javascript:alert(1)', '%url%', 'ftp://h/x', '//h/x', 'https://%path%/x',
     'https://h%url%/x', 'https:// h/x', 'https:///x', ' https://h/x', "https://h/x\n"].each do |p|
      refute LP.valid?(p), p.inspect
    end
    refute LP.valid?("https://h/#{'a' * LP::MAX_LENGTH}")
  end

  def test_the_four_replacements_are_percent_encoded
    pattern = 'https://h/f?u=%url%&p=%path%&t=%title%&i=%id%'
    got = LP.expand(pattern, url: 'file://fs/部 門/a.docx', path: '\\\\fs\\a b.docx', title: 'a&b.docx', id: 'x/y?z#w')
    assert_equal 'https://h/f?u=file%3A%2F%2Ffs%2F%E9%83%A8%20%E9%96%80%2Fa.docx&p=%5C%5Cfs%5Ca%20b.docx' \
                 '&t=a%26b.docx&i=x%2Fy%3Fz%23w', got
  end

  def test_a_value_is_not_replaced_again_and_unknown_marks_stay
    assert_equal 'https://h/%25path%25/%other%/%2F', LP.expand('https://h/%url%/%other%/%2F', url: '%path%')
    assert_equal 'https://h/', LP.expand('https://h/%path%', {})
  end

  def test_a_user_info_in_the_host_is_not_valid
    refute LP.valid?('https://trusted.example@elsewhere.example/%path%')
    refute LP.valid?('https://h\\x/%path%')
    assert LP.valid?('https://h/x@y/%path%') # an @ after the host is only text
  end

  def test_a_value_that_is_a_dot_segment_makes_no_link
    pattern = 'https://h/files/%path%'
    assert_nil LP.expand(pattern, path: '..')
    assert_nil LP.expand(pattern, path: '.')
    assert_nil LP.expand('https://h/%title%/%path%', title: 'a', path: '..')
    assert_equal 'https://h/files/a..b', LP.expand(pattern, path: 'a..b')
    assert_equal 'https://h/files/..%2Fx', LP.expand(pattern, path: '../x') # one segment, not a dot segment
    assert_equal 'https://h/files/', LP.expand(pattern, path: '') # nothing to follow, nothing to leave
    assert_equal 'https://h/files/x', LP.expand(pattern, path: 'x', title: '..') # a value not used does not count
  end

  def test_path_slash_keeps_the_slashes_and_turns_backslashes_into_them
    pattern = 'https://h/files/%path_slash%'
    assert_equal 'https://h/files/fileserver/' + ERB::Util.url_encode('規程集') + '/' + ERB::Util.url_encode('旅費 規程.pdf'),
                 LP.expand(pattern, path: '\\\\fileserver\\規程集\\旅費 規程.pdf')
    assert_equal 'https://h/files/a/b/c.docx', LP.expand(pattern, path: '/a//b/c.docx') # POSIX, doubled slash
    assert_equal 'https://h/files/', LP.expand(pattern, path: '')
    assert_equal 'https://h/files/a%3Fb/c%23d', LP.expand(pattern, path: 'a?b/c#d') # nothing else can end the path
    assert_equal 'https://h/files/a%2Fb', LP.expand('https://h/files/%path%', path: 'a/b') # %path% as ever
  end

  def test_path_slash_with_a_dot_part_makes_no_link
    pattern = 'https://h/files/%path_slash%'
    assert_nil LP.expand(pattern, path: 'a\\..\\b')
    assert_nil LP.expand(pattern, path: '../x')
    assert_nil LP.expand(pattern, path: './x')
    assert_equal 'https://h/files/a..b/x', LP.expand(pattern, path: 'a..b/x')
    assert_equal 'https://h/files/x', LP.expand('https://h/files/x', path: '../x') # not used: no matter
  end
end
