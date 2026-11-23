# frozen_string_literal: true

require_relative '../light_helper'
require 'socket'
require 'tempfile'

# Asking Tika Server (design D-36), against a small server on a local port that answers as told
class TikaClientTest < Minitest::Test
  # Answers each connection with status and body (the body written in pieces of 64 KB), then closes it. Records how
  # many bytes of the body it could write before the client went away.
  class FakeServer
    attr_reader :port, :written

    def initialize(status, body)
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @written = 0
      @thread = Thread.new do
        loop do
          socket = @server.accept
          serve(socket, status, body)
        rescue IOError, SystemCallError
          break if @server.closed?
        end
      end
    end

    def stop
      @server.close
      @thread.join(2)
    end

    private

    def serve(socket, status, body)
      length = 0
      while (line = socket.gets) && line != "\r\n"
        length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
      end
      socket.read(length) if length.positive?
      socket.write("HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n")
      body.bytes.each_slice(64 * 1024) do |piece|
        socket.write(piece.pack('C*'))
        @written += piece.size
      end
    rescue IOError, SystemCallError
      nil # the client stopped reading
    ensure
      socket.close
    end
  end

  def with_server(status, body)
    server = FakeServer.new(status, body)
    yield SolrSearch::TikaClient.new("http://127.0.0.1:#{server.port}", read_timeout: 5), server
  ensure
    server&.stop
  end

  def with_file
    Tempfile.create('tika') do |f|
      f.write('x')
      f.flush
      yield f.path
    end
  end

  def test_the_whole_text_when_there_is_no_limit
    with_server('200 OK', 'テキスト') do |tika, _|
      with_file {|path| assert_equal 'テキスト', tika.text(path, filename: 'a.txt') }
    end
  end

  # M4 review, #6: a huge text is not read to the end to be cut afterwards
  def test_the_answer_is_read_no_further_than_the_limit
    body = 'a' * (8 * 1024 * 1024)
    with_server('200 OK', body) do |tika, server|
      with_file do |path|
        text = tika.text(path, filename: 'a.txt', max_bytes: 100_000)
        assert_operator text.bytesize, :>=, 100_000
        assert_operator text.bytesize, :<, 1024 * 1024, 'read far beyond the limit'
      end
      sleep 0.2
      assert_operator server.written, :<, body.bytesize, 'the server could write the whole body: it was read to the end'
    end
  end

  def test_what_tika_answers_is_the_kind_of_error
    {'415 Unsupported Media Type' => :unsupported, '422 Unprocessable Entity' => :unprocessable,
     '500 Internal Server Error' => :unavailable, '503 Service Unavailable' => :unavailable}.each do |status, kind|
      with_server(status, 'no') do |tika, _|
        with_file do |path|
          error = assert_raises(SolrSearch::TikaClient::Error) { tika.text(path, filename: 'a.pdf') }
          assert_equal kind, error.kind, status
        end
      end
    end
  end

  def test_alive_when_tika_answers_get
    with_server('200 OK', 'This is Tika Server') {|tika, _| assert tika.alive? }
    with_server('503 Service Unavailable', 'no') {|tika, _| refute tika.alive? }
  end

  def test_not_alive_when_nothing_listens
    port = TCPServer.open('127.0.0.1', 0) {|s| s.addr[1] } # free again once closed
    tika = SolrSearch::TikaClient.new("http://127.0.0.1:#{port}")
    refute tika.alive?
    with_file do |path|
      error = assert_raises(SolrSearch::TikaClient::Error) { tika.text(path, filename: 'a.pdf') }
      assert_equal :unavailable, error.kind
    end
  end

  # Where the address comes from (design D-61): blanks are not an address
  def test_resolve_takes_the_saved_address_then_the_environment_then_the_default
    assert_equal ['http://a:9998', :screen], SolrSearch::TikaClient.resolve(saved: ' http://a:9998 ', env: 'http://b:9998')
    assert_equal ['http://b:9998', :env], SolrSearch::TikaClient.resolve(saved: '  ', env: 'http://b:9998')
    assert_equal ['http://tika:9998', :default], SolrSearch::TikaClient.resolve(saved: nil, env: '')
  end

  # https (Gemini review 2026-11-09, No 1): spoken to as TLS. This server waits for a plain request, so the handshake runs
  # out of time (a real Tika speaking http answers at once: an SSL error, docs/experiments/tika-url); either way the server
  # is unreachable, not a crash
  def test_an_https_address_is_spoken_to_as_tls
    server = FakeServer.new('200 OK', 'text')
    client = SolrSearch::TikaClient.new("https://127.0.0.1:#{server.port}", open_timeout: 1, read_timeout: 1)
    Tempfile.create('tika') do |file|
      error = assert_raises(SolrSearch::TikaClient::Error) { client.text(file.path, filename: 'a.txt') }
      assert_equal :unavailable, error.kind
    end
    refute client.alive?(read_timeout: 2)
  ensure
    server&.stop
  end
end
