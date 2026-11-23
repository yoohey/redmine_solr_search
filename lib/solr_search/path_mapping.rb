# frozen_string_literal: true

module SolrSearch
  # How an external source shows where a document is (design D-35): the path in the index is the one the crawler saw (in
  # the ManifoldCF container: /mnt/c/Users/...), and a person looks for the file by the path of their own system
  # (C:\Users\...). A source may say: a path that starts with FROM is shown with TO in its place. The rest of the path
  # is written with the separator TO uses: \ when TO has a backslash or starts with a drive letter (C:), otherwise /.
  module PathMapping
    MAX_LENGTH = 500

    # Whether from has anything left once trailing separators are stripped (a bare "/" or "\" would map nothing; M4 review, #25)
    def self.valid_from?(from)
      from.to_s.sub(%r{[/\\]+\z}, '').present?
    end

    # path: the path in the index. from, to: the source's setting (either may be blank: no mapping).
    # A path that does not start with from (at a boundary: /mnt/c does not match /mnt/cd) is shown as it is.
    # The form of an external source previews the mapping with the same rule in JavaScript (mapPath in
    # app/views/solr_search_sources/_form.html.erb): a change here goes there too.
    def self.map(path, from, to)
      path = path.to_s
      return path if from.blank? || to.blank?

      head = from.to_s.sub(%r{[/\\]+\z}, '')
      return path if head.empty? || !path.start_with?(head)

      rest = path[head.length..]
      return path unless rest.empty? || rest.start_with?('/', '\\') # either separator: a path of Windows or of Unix

      separator = to.include?('\\') || to.match?(/\A[A-Za-z]:/) ? '\\' : '/'
      to.sub(%r{[/\\]+\z}, '') + rest.tr('/\\', separator * 2)
    end
  end
end
