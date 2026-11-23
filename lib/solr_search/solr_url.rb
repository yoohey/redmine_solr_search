# frozen_string_literal: true

require 'uri'

module SolrSearch
  # The address of Solr (design D-43): what the admin page may save, and which address is used. Pure (no database, no
  # environment of its own): the callers hand in what they read, so that a light test checks it.
  module SolrUrl
    # Raised for an address the page must not save. reason: :format, :scheme, :host, :userinfo or :query (the screen has
    # a text for each); the message is for the log.
    class Invalid < StandardError
      attr_reader :reason

      def initialize(message, reason)
        super(message)
        @reason = reason
      end
    end

    module_function

    # The address as it is kept: stripped, without the slash at its end. Only the writing is checked, not whether
    # Solr answers there (a Solr that is down for a moment must not keep the address from being saved).
    # Blank is not an address: the caller takes it as "use the environment variable".
    def normalize(text)
      url = text.to_s.strip
      raise Invalid.new('blank', :format) if url.empty?
      raise Invalid.new('white space in the address', :format) if url.match?(/\s/)

      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        raise Invalid.new('not an address', :format)
      end
      raise Invalid.new("the scheme is #{uri.scheme.inspect}", :scheme) unless %w[http https].include?(uri.scheme)
      raise Invalid.new('no host name', :host) if uri.host.to_s.empty?
      raise Invalid.new('user name or password in the address', :userinfo) if uri.userinfo
      raise Invalid.new('query or fragment in the address', :query) if uri.query || uri.fragment

      # Only the characters of a host and a path. The address is also written into a command that an administrator copies
      # into a shell (SchemaCheck.create_command): a $, a backtick, a quote or a ; would be read there (M6 review 4)
      raise Invalid.new('a character that is not part of an address', :format) unless url.match?(%r{\A[A-Za-z0-9._~:/%+\[\]-]+\z})

      url.sub(%r{/+\z}, '')
    end

    # [address, where it comes from] or nil. saved: the one set on the admin page (blank: none); env: the environment
    # variable SOLR_URL. The saved one comes first.
    def resolve(saved:, env:)
      return [saved.to_s.strip, :screen] unless saved.to_s.strip.empty?
      return [env.to_s.strip, :env] unless env.to_s.strip.empty?

      nil
    end
  end
end
