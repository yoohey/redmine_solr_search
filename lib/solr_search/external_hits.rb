# frozen_string_literal: true

module SolrSearch
  # Which hits of a result are external documents and which are Redmine's (design D-33). The filter query already lets
  # through only what it should; this is the second guard before anything is shown. A document of a source says its own
  # type and group id, so neither is trusted: a group with a hit of Redmine's is Redmine's (what rode along from an
  # external collection is dropped, and Redmine's own check of the record follows); a hit of Redmine's must say its
  # source is redmine; an external hit is kept only for a source asked for (security review 2026-10-06, 1).
  module ExternalHits
    # Cleans the hits of each group in place. Returns the group ids that are external documents (a set).
    def self.sort_out(groups, sources)
      external_group_ids = Set.new
      groups.each do |group|
        external, redmine = group.hits.partition(&:external?)
        external = external.select {|hit| sources.include?(hit.source)}
        # source is nil when the request did not ask for it: then no external document can have come
        redmine = redmine.select {|hit| hit.source.nil? || hit.source == SOURCE}
        if redmine.any?
          group.hits = redmine
        else
          group.hits = external
          external_group_ids << group.group_id if external.any?
        end
      end
      external_group_ids
    end
  end
end
