# frozen_string_literal: true

require 'erb'

module SolrSearch
  # The link format of an external source (design D-35): a URL with %url%, %path%, %path_slash%, %title% and %id% in it, which a
  # search hit's own values replace, as Redmine does for the URL format of a custom field. What is kept is only a
  # starting point: the hit's element carries the same values as data attributes, for those who make the link in
  # their own way (a view customization, a script).
  module LinkPattern
    PLACEHOLDERS = %w[url path path_slash title id].freeze
    MAX_LENGTH = 1000
    DOT_SEGMENTS = ['.', '..'].freeze

    # The scheme and the host are written out: http or https (a browser does not follow a link from a page to a
    # file:// address, and javascript: must never come out), and a host of the administrator's own, never one a
    # hit's value could make.
    # No white space or control character anywhere.
    # No user info (https://trusted@elsewhere/) either: the host is the one before any @.
    VALID = %r{\Ahttps?://[^/?#%@\\\s]+(?:[/?#]\S*)?\z}i
    PLACEHOLDER = /%(#{PLACEHOLDERS.join('|')})%/

    def self.valid?(pattern)
      pattern.is_a?(String) && pattern.length <= MAX_LENGTH && VALID.match?(pattern)
    end

    # values: {url:, path:, title:, id:}. Each value is percent-encoded (every character but letters, digits and
    # - . _ ~; so a / becomes %2F), and a value is not looked into again for a placeholder. %path_slash% is the path
    # as the parts of a URL path: \ turned into /, each part encoded and the / kept, no / at the start (a UNC path
    # \\server\share\a.pdf gives server/share/a.pdf). nil when a value used is "." or "..", or has such a part (for
    # %path_slash%): a browser folds it into the path and leaves the administrator's prefix (security review
    # 2026-10-06, 3).
    def self.expand(pattern, values)
      parts = path_parts(values[:path])
      used = pattern.scan(PLACEHOLDER).flatten
      return nil if used.any? {|name| name == 'path_slash' ? parts.any? {|part| DOT_SEGMENTS.include?(part)} : DOT_SEGMENTS.include?(values[name.to_sym].to_s)}

      pattern.gsub(PLACEHOLDER) do
        name = Regexp.last_match(1)
        name == 'path_slash' ? parts.map {|part| ERB::Util.url_encode(part)}.join('/') : ERB::Util.url_encode(values[name.to_sym].to_s)
      end
    end

    # The parts of a path written with \ or /, without empty ones
    def self.path_parts(path)
      path.to_s.tr('\\', '/').split('/').reject(&:empty?)
    end
  end
end
