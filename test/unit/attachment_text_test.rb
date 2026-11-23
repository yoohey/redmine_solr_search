# frozen_string_literal: true

require_relative '../light_helper'
require 'tempfile'

# The text of an attachment, or the reason there is none (design D-36)
class AttachmentTextTest < Minitest::Test
  Attachment = Struct.new(:filename, :filesize, :content_type, :diskfile, keyword_init: true)

  # Stands in for TikaClient
  class FakeTika
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def text(path, filename: nil, content_type: nil, max_bytes: nil)
      @calls << [path, filename, content_type]
      raise @answer if @answer.is_a?(Exception)

      @answer
    end
  end

  def with_file(name = 'a.pdf', size = nil, type = 'application/pdf')
    Tempfile.create('att') do |f|
      f.write('x')
      f.flush
      yield Attachment.new(filename: name, filesize: size || 1, content_type: type, diskfile: f.path)
    end
  end

  def extract(att, answer, **options)
    tika = FakeTika.new(answer)
    [SolrSearch::AttachmentText.new(tika: tika, **options).extract(att), tika]
  end

  def test_the_text_of_a_file
    with_file do |att|
      result, tika = extract(att, 'テキスト')
      assert result.ok?
      assert_equal 'テキスト', result.text
      assert_equal [[att.diskfile, 'a.pdf', 'application/pdf']], tika.calls
    end
  end

  def test_a_file_whose_extension_is_not_listed_is_not_sent_to_tika_whatever_its_type
    # an archive, an image, a file with no extension, a file with a misleading type: only the extension counts (D-47)
    [['x.ZIP', 'application/zip'], ['x.tar.gz', 'application/octet-stream'], ['noext', 'application/pdf'],
     ['b.jar', nil], ['p.png', 'image/png'], ['x.exe', 'application/pdf']].each do |name, type|
      with_file(name, 1, type) do |att|
        result, tika = extract(att, 'never')
        assert_equal :not_listed, result.status, name
        assert_empty tika.calls
      end
    end
  end

  def test_the_default_list_is_office_text_and_pdf_without_images_and_archives
    d = SolrSearch::AttachmentText::DEFAULT_EXTENSIONS
    %w[docx xlsx pptx odt rtf txt md csv json xml html htm pdf].each {|ext| assert_includes d, ext }
    %w[png jpg jpeg gif zip tar gz 7z jar exe].each {|ext| refute_includes d, ext }
  end

  def test_the_extension_is_the_last_one_in_any_case
    with_file('Report.DOCX', 1, nil) {|att| assert extract(att, 'text').first.ok? }
    with_file('notes.tar.gz', 1, nil) do |att|
      assert_equal :not_listed, extract(att, 'x').first.status
      assert extract(att, 'text', extensions: %w[gz]).first.ok? # "gz" is what it is
    end
  end

  def test_whoever_lists_an_archive_gets_its_text_whatever_its_type
    with_file('x.zip', 1, 'application/zip') do |att|
      result, tika = extract(att, 'inside', extensions: %w[zip])
      assert result.ok?
      assert_equal 'inside', result.text
      assert_equal 1, tika.calls.size
    end
  end

  def test_a_file_that_is_not_in_a_given_list_is_not_sent_even_if_it_is_a_default_one
    with_file('a.pdf') do |att|
      result, tika = extract(att, 'never', extensions: %w[txt])
      assert_equal :not_listed, result.status
      assert_empty tika.calls
    end
  end

  def test_the_list_is_read_from_what_is_written
    parse = SolrSearch::AttachmentText.method(:parse_extensions)
    assert_equal [%w[doc docx pdf], []], parse.call('doc, .DOCX  pdf')
    assert_equal [%w[a b c], []], parse.call("a\nb,c;a")                        # lines, commas, semicolons; each once
    assert_equal [%w[doc xlsx], ['x/y', '*', 'a.b']], parse.call('doc x/y * a.b xlsx')
    assert_equal [%w[c++ a_b a-b], []], parse.call('c++ a_b a-b')
    assert_equal [[], []], parse.call('')
    assert_equal [[], []], parse.call(nil)
    assert_equal [%w[txt], []], parse.call('txt、')                              # the Japanese comma too
  end

  def test_a_file_too_big_is_not_sent
    with_file('a.pdf', 101) do |att|
      result, tika = extract(att, 'never', max_file_bytes: 100)
      assert_equal :too_large, result.status
      assert_empty tika.calls
    end
  end

  def test_a_file_that_is_not_on_the_disk
    att = Attachment.new(filename: 'a.pdf', filesize: 1, content_type: 'application/pdf', diskfile: '/nonexistent/a.pdf')
    result, tika = extract(att, 'never')
    assert_equal :missing, result.status
    assert_empty tika.calls
  end

  def test_what_tika_says_is_the_status
    with_file do |att|
      %i[unsupported unprocessable unavailable].each do |kind|
        result, = extract(att, SolrSearch::TikaClient::Error.new("no #{kind}", kind))
        assert_equal kind, result.status
        assert_nil result.text
        assert_equal "no #{kind}", result.message
      end
    end
  end

  # Anything else that goes wrong with one file (M4 review, #4: a line break in the content type made Net::HTTP raise)
  # is that file's failure: indexed without text, the batch and the run go on
  def test_any_other_error_is_the_failure_of_that_file
    with_file do |att|
      result, = extract(att, ArgumentError.new('header field value cannot include CR/LF'))
      assert_equal :error, result.status
      assert_nil result.text
      assert_equal 'ArgumentError: header field value cannot include CR/LF', result.message
    end
  end

  def test_a_content_type_of_another_shape_is_not_sent_to_tika
    {'application/pdf' => 'application/pdf', 'text/plain; charset=UTF-8' => 'text/plain',
     'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
       'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
     "text/plain\nX-Injected: 1" => nil, 'text/plain\r' => nil, 'pdf' => nil, '' => nil, nil => nil}.each do |given, sent|
      got = SolrSearch::TikaClient.safe_content_type(given)
      sent ? assert_equal(sent, got, given.inspect) : assert_nil(got, given.inspect)
    end
  end

  def test_the_text_is_cut_at_the_limit_without_cutting_a_character
    text = 'あ' * 10 # 30 bytes
    assert_equal text, SolrSearch::AttachmentText.truncate(text, 30)
    assert_equal 'あ' * 3, SolrSearch::AttachmentText.truncate(text, 10) # 9 bytes: the tenth is half a character
    with_file do |att|
      result, = extract(att, text, max_text_bytes: 12)
      assert_equal 'あ' * 4, result.text
    end
  end
end
