# frozen_string_literal: true

module SolrSearch
  # What the admin page needs to offer a partial reindex (design D-57): the custom fields the index has values of that
  # Redmine no longer has, and how many issues a scope means. Reads Solr and the database; the pure rules are in
  # ReindexScope.
  module ReindexTargets
    module_function

    # [{id:, count:}] of the custom fields whose values the index has in issue documents and Redmine has no custom field
    # for (a field deleted), by id; count: the issues of the index with a value of it (not none). One Luke call, and one count each.
    def deleted_fields(client)
      indexed = ReindexScope.field_ids(client.field_names)
      known = IssueCustomField.where(id: indexed).pluck(:id)
      # Luke lists a field as long as a segment has it, also after every document that had a value was written again; the ones
      # with no issue left are not offered
      (indexed - known).filter_map do |id|
        count = indexed_issue_count(client, id)
        {id: id, count: count} if count.positive?
      end
    end

    # How many issue documents of the index have a value of the custom field
    def indexed_issue_count(client, field_id)
      client.select(q: ReindexScope.solr_query([field_id]), fq: ["source:#{SOURCE}", '{!term f=type}issue'], rows: 0)
            .dig('response', 'numFound')
    end

    # About how many issues the scope means (the page says "about"): the trackers' issues are counted in the database;
    # for fields, the larger of the issues the index has a value of the fields for and those Redmine has a value for (the
    # run takes both; the real number is between this and their sum).
    def estimate(scope, client)
      ids = ReindexScope.ids_of(scope)
      case ReindexScope.kind(scope)
      when 'trackers'
        Indexer.scope('issue').where(tracker_id: ids).count
      when 'fields'
        in_index = client.select(q: ReindexScope.solr_query(ids), fq: ["source:#{SOURCE}", '{!term f=type}issue'], rows: 0)
                         .dig('response', 'numFound')
        in_redmine = CustomValue.where(customized_type: 'Issue', custom_field_id: ids).where.not(value: [nil, '']).distinct.count(:customized_id)
        [in_index, in_redmine].max
      end
    end
  end
end
