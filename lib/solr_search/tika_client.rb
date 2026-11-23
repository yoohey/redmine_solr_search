# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'uri'

module SolrSearch
  # Asks an Apache Tika Server for the text of a file (design D-36). Tika runs in a container of its own: a broken or huge
  # file takes only that with it, not Redmine or Solr. Standard library only, like Client.
  class TikaClient
    # kind: :unsupported (415: a type Tika has no parser for), :unprocessable (422: damaged, encrypted ...), :unavailable
    # (no answer in time, refused, a failure of the server itself: worth trying again later)
    class Error < StandardError
      attr_reader :kind

      def initialize(message, kind)
        super(message)
        @kind = kind
      end
    end

    DEFAULT_URL = 'http://tika:9998'
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 120 # a big spreadsheet takes a while; the first request after the start loads the parsers (~7 s)
    ALIVE_TIMEOUT = 5

    # The address in use and where it comes from (design D-61): [url, :screen, :env or :default]. saved: the one set on the
    # admin page (blank: none); env: the environment variable TIKA_URL. Pure, like SolrUrl.resolve: a light test checks it.
    def self.resolve(saved:, env:)
      return [saved.to_s.strip, :screen] unless saved.to_s.strip.empty?
      return [env.to_s.strip, :env] unless env.to_s.strip.empty?

      [DEFAULT_URL, :default]
    end

    # A client for the address in use (Settings.tika_address), read at each call: a change on the admin page is used by the
    # next run, in the scheduler too
    def self.configured(read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT)
      new(Settings.tika_address.first, read_timeout: read_timeout, open_timeout: open_timeout)
    end

    attr_reader :base_url

    def initialize(base_url, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      @base_url = base_url.to_s.chomp('/')
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # The text of the file at path, as UTF-8. The file's own name is not sent (Tika only needs the extension, and a header
    # holds no Japanese); content_type helps it choose the parser. max_bytes: the answer is read bit by bit and no further
    # than that (M4 review, #6): a 50 MB file can make a text of hundreds of MB, which need not be held to be cut.
    def text(path, filename: nil, content_type: nil, max_bytes: nil)
      uri = URI("#{@base_url}/tika")
      File.open(path, 'rb') do |file|
        req = Net::HTTP::Put.new(uri)
        req['Accept'] = 'text/plain'
        type = self.class.safe_content_type(content_type)
        req['Content-Type'] = type if type
        req['Content-Disposition'] = %(attachment; filename="file#{safe_extension(filename)}")
        req.content_length = file.size
        req.body_stream = file
        res = nil
        body = +''
        # thrown out of Net::HTTP.start, which then closes the connection: leaving only read_body, Net::HTTP would read
        # the rest of the answer anyway
        catch(:enough) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @open_timeout,
                                              read_timeout: @read_timeout) do |http|
            http.request(req) do |answer|
              res = answer
              next unless answer.is_a?(Net::HTTPSuccess)

              answer.read_body do |chunk|
                body << chunk
                throw :enough if max_bytes && body.bytesize >= max_bytes
              end
            end
          end
        end
        interpret(res, body)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise Error.new("Tika #{e.class}", :unavailable)
    rescue Net::ProtocolError, Net::HTTPBadResponse => e
      raise Error.new("Tika answered badly: #{e.class}", :unavailable)
    # an SSL error: an https address where Tika speaks http, or a certificate this host does not trust
    rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
      raise Error.new("Tika unreachable: #{e.class}: #{e.message}", :unavailable)
    end

    # Whether Tika itself answers (GET /tika: "This is Tika Server ..."). When a file gets no answer while this is true,
    # the file is what is wrong, not Tika (design D-36; M4 review, #5). read_timeout: how long to wait for the answer once
    # connected (the status tab waits less: Gemini review 2026-11-09, Q2).
    def alive?(read_timeout: ALIVE_TIMEOUT)
      uri = URI("#{@base_url}/tika")
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @open_timeout,
                                                read_timeout: read_timeout) do |http|
        http.get(uri.path)
      end
      res.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    private

    def interpret(res, body)
      case res
      when Net::HTTPSuccess then body.force_encoding(Encoding::UTF_8).scrub('')
      when Net::HTTPUnsupportedMediaType then raise Error.new('Tika has no parser for this type (415)', :unsupported)
      when Net::HTTPUnprocessableEntity then raise Error.new('Tika could not read this file (422)', :unprocessable)
      else raise Error.new("Tika answered #{res.code}", :unavailable)
      end
    end

    # The type as Redmine has it ("application/pdf"), or nil when it has some other shape: it comes from the uploader, and
    # a line break in it would make Net::HTTP raise (M4 review, #4). Without it Tika goes by the content.
    def self.safe_content_type(content_type)
      type = content_type.to_s.split(';').first.to_s.strip
      type if type.match?(%r{\A[\w.+-]+/[\w.+-]+\z})
    end

    # ".pdf" or "" — only letters and digits, so that nothing odd goes into a header
    def safe_extension(filename)
      ext = File.extname(filename.to_s).downcase
      ext.match?(/\A\.[a-z0-9]{1,10}\z/) ? ext : ''
    end
  end
end
