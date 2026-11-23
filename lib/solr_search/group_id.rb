# frozen_string_literal: true

module SolrSearch
  # The id of a container, the thing that a result of the search is (design D-27): the kind and the number of a record of Redmine,
  # "issue-12", "wiki_page-5", "document-3", "project-1", "version-2"; an external document's is its address, which is not of that
  # form. What reads an id (the search screen, the trial search of the admin page) asks here (Q-40).
  module GroupId
    FORM = /\A([a-z_]+)-(\d+)\z/

    module_function

    def build(kind, number)
      "#{kind}-#{number}"
    end

    # "issue-12" => ['issue', 12]; nil for an id of another form (an external document's)
    def parse(group_id)
      match = FORM.match(group_id.to_s)
      match && [match[1], match[2].to_i]
    end

    # "issue-12" => "issue"; nil for another form
    def kind(group_id)
      parse(group_id)&.first
    end

    # ["issue-12", "issue-3", "document-7", "file://x"] => {"issue" => [12, 3], "document" => [7]} (the other forms are left out)
    def numbers_by_kind(group_ids)
      group_ids.each_with_object(Hash.new {|h, k| h[k] = [] }) do |group_id, found|
        kind, number = parse(group_id)
        found[kind] << number if kind
      end.tap {|found| found.default_proc = nil }
    end
  end
end
