# frozen_string_literal: true

module SolrSearch
  # Sends Redmine data to the "redmine" collection (design D-22). For now only the full reindex: every record
  # Redmine has is sent again and overwrites its document. Documents only Solr still has (records deleted in
  # Redmine) are left; removing them is the job of the reconciliation (D-22, process 3).
  class Indexer
    BATCH_SIZE = 500

    # type => [scope, document builder]. The scope decides what is indexed at all (docs/schema.md 3.1).
    # joins: a note whose issue or a wiki page whose wiki is gone (an old database may have them) is out of scope, not
    # a record that stops every crawl (M1 review A2).
    TYPES = {
      # project and tracker decide the custom fields an issue has (D-31); preloaded, they are read once per batch
      'issue' => [-> { Issue.preload(:project, :tracker, :custom_values) }, RedmineDocuments.method(:issue)],
      # only notes with text (not the attribute changes alone); private notes too, the filter decides who sees them
      # (design D-30)
      'journal' => [
        # the issue's values go on its notes, the custom fields among them (D-49): preloaded as for the issues
        -> { Journal.joins(:issue).where(journalized_type: 'Issue').where.not(notes: [nil, '']).preload(issue: %i[project tracker custom_values]) },
        RedmineDocuments.method(:journal)
      ],
      'wiki_page' => [-> { WikiPage.joins(:wiki).preload(:content, :wiki) }, RedmineDocuments.method(:wiki_page)],
      'document' => [-> { Document.all }, RedmineDocuments.method(:document_record)],
      # attachments: the scope is the one the reconciliation compares with; sending them is the AttachmentIndexer's
      # (the text of the files: slow, so not part of a reindex of everything or of the incremental crawl; design D-36)
      'attachment' => [-> { AttachmentIndexer.scope }, nil]
    }.freeze

    ATTACHMENT = 'attachment'

    # The types a reindex sends when none are asked for, and the incremental crawl covers: not attachments, whose text
    # is made by Tika, which is slow (design D-36). TYPES=attachment asks for them.
    def self.types
      TYPES.keys - [ATTACHMENT]
    end

    # Every type there is, attachments too (what the reconciliation walks, and what a type may be named)
    def self.all_types
      TYPES.keys
    end

    def self.check_types!(types)
      unknown = types - all_types
      raise ArgumentError, "unknown type(s): #{unknown.join(', ')} (known: #{all_types.join(', ')})" if unknown.any?
    end

    # The records of a type that belong in the index. The one definition of "in scope", shared by every process that
    # sends or removes documents (design D-22). The search screen checks with Redmine's own rules instead (D-30).
    def self.scope(type)
      TYPES.fetch(type).first.call
    end

    def initialize(client: Client.from_env(SolrSearch.collection), logger: nil)
      @client = client
      @logger = logger
    end

    # Sends every record of the given types (default: all) and commits once at the end.
    # Returns {type => {'sent' => number of documents sent}} (the counts of a run, SolrSearch::TaskRun).
    def reindex(types = self.class.types)
      self.class.check_types!(types)
      counts = (types - [ATTACHMENT]).index_with {|type| {'sent' => reindex_type(type)}}
      counts.merge!(attachment_indexer.reindex) if types.include?(ATTACHMENT)
      @client.commit
      counts
    end

    # The incremental crawl (design D-22, process 1): what changed since the given time. Records still in scope are
    # sent; those that fell out of it (a note emptied) are removed. No explicit commit: commitWithin.
    # Returns {type => {'sent' => n, 'deleted' => n}}.
    def incremental(since)
      counts = {}
      issue_ids = Issue.where(updated_on: since..).pluck(:id)
      send_changed('issue', issue_ids, counts)
      # every note of a changed issue too: each carries the issue's permission values (D-27, D-30)
      notes = Journal.where(journalized_type: 'Issue')
      send_changed('journal', notes.where(updated_on: since..).or(notes.where(journalized_id: issue_ids)).pluck(:id), counts)
      send_changed('wiki_page', WikiPage.joins(:content).where(wiki_contents: {updated_on: since..}).pluck(:id), counts)
      send_changed('document', Document.where(created_on: since..).pluck(:id), counts)
      # the attachments of a changed issue: its permission values (project, private ...) may have changed; set in place,
      # the text is not made again (design D-36)
      counts.merge!(attachment_indexer.refresh(Attachment.where(container_type: 'Issue', container_id: issue_ids).pluck(:id)))
      counts
    end

    # A partial reindex (design D-57): the issues of a scope, their notes, and the permission values and custom field values
    # of their attachments (no text, so no Tika). Every document is sent whole and overwrites the old one, so a value
    # the issue no longer has (a custom field it lost) is gone. Removes nothing (the reconciliation does).
    # scope: ReindexScope.normalize's result. Returns {type => {'sent' => n}}; the attachments' as refresh gives them.
    def reindex_partial(scope)
      counts = {'issue' => {'sent' => 0}, 'journal' => {'sent' => 0}}
      attachments = 0
      scope_issue_ids(scope).each_slice(BATCH_SIZE) do |ids|
        counts['issue']['sent'] += send_whole('issue', self.class.scope('issue').where(id: ids))
        counts['journal']['sent'] += send_whole('journal', self.class.scope('journal').where(journalized_id: ids))
        attachment_ids = Attachment.where(container_type: 'Issue', container_id: ids).pluck(:id)
        attachments += attachment_indexer.refresh(attachment_ids).dig('attachment', 'sent') if attachment_ids.any?
        log "partial: #{counts['issue']['sent']} issues, #{counts['journal']['sent']} notes, #{attachments} attachments"
      end
      @client.commit
      counts.merge('attachment' => {'sent' => attachments, 'deleted' => 0})
    end

    # The ids of the issues a scope means, read when the run starts. Trackers: the issues that have one of them. Fields:
    # the issues the index has a value of the field for (a value the field no longer should have: the field left the
    # tracker, was deleted, ...) and the issues Redmine has a value of the field for (a value the index does not have yet:
    # a field made a filter, ...).
    def scope_issue_ids(scope)
      ids = ReindexScope.ids_of(scope)
      case ReindexScope.kind(scope)
      when 'trackers'
        self.class.scope('issue').where(tracker_id: ids).pluck(:id)
      when 'fields'
        in_index = @client.all_ids(["source:#{SOURCE}", '{!term f=type}issue', ReindexScope.solr_query(ids)]) do |n|
          log "partial: #{n} issues read from Solr"
        end.map {|id| id.delete_prefix('issue-').to_i}
        in_redmine = CustomValue.where(customized_type: 'Issue', custom_field_id: ids).where.not(value: [nil, ''])
                                .distinct.pluck(:customized_id)
        # only issues that are in scope (an issue left in the index after its deletion is the reconciliation's): the ids of the
        # scope are read and cut with them, not put in one long IN list
        wanted = (in_index + in_redmine).to_set
        self.class.scope('issue').pluck(:id).select {|id| wanted.include?(id)}
      else
        raise ArgumentError, "unknown scope: #{scope.inspect}"
      end.sort
    end

    # Types whose edits leave no timestamp (design D-22, process 2): a wiki page renamed or moved to another project
    # (wiki_pages has only created_on), a document edited (documents has only created_on).
    RESEND_TYPES = %w[wiki_page document].freeze

    # Process 2: every record of RESEND_TYPES sent again. No explicit commit: commitWithin.
    def resend
      counts = RESEND_TYPES.index_with {|type| {'sent' => reindex_type(type), 'deleted' => 0}}
      # and the attachments' file names, descriptions and permission values (edited without a timestamp; design D-36)
      counts.merge!(attachment_indexer.refresh)
    end

    # Process 3 (design D-22): removes what the index has and Redmine does not have in scope (deleted, or out of
    # scope without a timestamp to show it). Solr is read before Redmine: a record deleted in between is removed, one
    # created in between is not in Solr yet. Only one task runs at a time, so no crawl adds documents meanwhile.
    def reconcile
      self.class.all_types.index_with do |type|
        # a report for each page of ids keeps a long read alive (TaskRun::STALE_AFTER; M1 review A10)
        in_solr = @client.all_ids(["source:#{SOURCE}", "{!term f=type}#{type}"]) do |n|
          log "#{type}: #{n} ids read from Solr"
        end
        in_scope = self.class.scope(type).pluck(:id).to_set {|id| "#{type}-#{id}"}
        gone = in_solr.reject {|id| in_scope.include?(id)}
        gone.each_slice(BATCH_SIZE) {|ids| @client.delete_by_ids(ids)}
        log "#{type}: #{in_solr.size} in Solr, #{in_scope.size} in Redmine, #{gone.size} deleted"
        {'sent' => 0, 'deleted' => gone.size}
      end
    end

    private

    def send_whole(type, relation)
      builder = TYPES.fetch(type).last
      sent = 0
      relation.find_in_batches(batch_size: BATCH_SIZE) do |records|
        @client.add(records.map {|record| builder.call(record)})
        sent += records.size
      end
      sent
    end

    def attachment_indexer
      AttachmentIndexer.new(client: @client, logger: @logger)
    end

    # Sends the records of these ids that are in scope; removes from the index those that are not (or no longer
    # exist) but are still there. Checking first keeps the count of removals true: most notes out of scope (attribute
    # changes only) were never indexed.
    def send_changed(type, ids, counts)
      builder = TYPES.fetch(type).last
      count = counts[type] = {'sent' => 0, 'deleted' => 0}
      ids.each_slice(BATCH_SIZE) do |slice|
        records = self.class.scope(type).where(id: slice).to_a
        @client.add(records.map {|record| builder.call(record)})
        gone = @client.existing_ids((slice - records.map(&:id)).map {|id| "#{type}-#{id}"})
        @client.delete_by_ids(gone)
        count['sent'] += records.size
        count['deleted'] += gone.size
        log "#{type}: #{count['sent']} sent, #{count['deleted']} deleted"
      end
    end

    def reindex_type(type)
      builder = TYPES.fetch(type).last
      count = 0
      self.class.scope(type).find_in_batches(batch_size: BATCH_SIZE) do |records|
        @client.add(records.map {|record| builder.call(record)})
        count += records.size
        log "#{type}: #{count}"
      end
      count
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
