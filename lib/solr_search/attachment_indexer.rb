# frozen_string_literal: true

module SolrSearch
  # Sends the attachments of Redmine to the "redmine" collection, with the text Tika makes of the files (design D-36).
  # A class of its own: extracting text is slow and fails often, so it does not go with the incremental crawl.
  #
  #   crawl    process 5: the attachments the index does not have yet, newest first, as many as limit / the time allow
  #   reindex  process 4 for attachments: every attachment in scope, the text made again
  #   refresh  process 2 for attachments: file name, description and permission values set again, the text left
  #
  # An attachment is sent with whatever text there is. When there is none for a reason that stays (an extension that is not
  # in the list, D-47; a file too big, a damaged one), it is sent without: the file name and the description find it. When Tika does not answer for a
  # file but answers as such, the file is what is wrong: it is sent without text too (no_answer; M4 review, #5), so that
  # it does not stay first in line for ever. Only when Tika itself is down is a file not sent: the next crawl tries
  # again. Each one that ends without text by a failure (not a file whose extension is not listed nor a file too big,
  # left out on purpose) is written to Redmine's log, so that it can be looked into later (design D-36).
  class AttachmentIndexer
    BATCH_SIZE = 10
    # After this many in a row that Tika does not answer, the run stops: it would only wait for the timeouts
    GIVE_UP_AFTER = 3
    ID_SLICE = 1000
    # What refresh compares with the index (the fields of RedmineDocuments.attachment_refresh, not the text)
    REFRESH_FIELDS = %w[id type container_type group_id title updated_at item_id source project_id is_private author_id
                        assigned_to_id tracker_id status_id priority_id fixed_version_id category_id file_extension
                        start_date due_date issue_created_at issue_closed_at].join(',') + ',cfs_*,cfn_*,cfd_*'
    # Without text on purpose (design D-36): not written to the log
    LEFT_OUT = %i[ok not_listed too_large].freeze

    # The attachments that belong in the index (design D-36): attached to an issue, a wiki page, a document, a project or a
    # version that exists. The one definition of "in scope", shared with the reconciliation (Indexer.scope('attachment')).
    # An old database may have attachments of records that are gone; they are out of scope, not an error.
    def self.scope
      containers = {
        'Issue' => Issue.select(:id), 'WikiPage' => WikiPage.joins(:wiki).select(:id), 'Document' => Document.select(:id),
        'Project' => Project.select(:id), 'Version' => Version.select(:id)
      }
      containers.map {|type, ids| Attachment.where(container_type: type, container_id: ids)}.reduce(:or)
    end

    def initialize(client: Client.from_env(SolrSearch.collection), tika: TikaClient.configured, logger: nil)
      @client = client
      @tika = tika
      # what is set on the settings screen (design D-47), read when the run starts: a change is used by the next run
      @text = AttachmentText.new(tika: tika, extensions: Settings.attachment_extensions,
                                 max_file_bytes: Settings.attachment_max_file_bytes, max_text_bytes: Settings.attachment_max_text_bytes)
      @logger = logger
    end

    # Process 5. Returns {'attachment' => {'sent' => n, 'with_text' => n, 'without_text' => {status => n}, 'deferred' => n,
    # 'remaining' => n}}: deferred are those Tika did not answer for; remaining, those left for the next run.
    # limit: the most to take; seconds: stops starting new ones after that long.
    # When Tika does not answer at all, the run fails at once (recorded as failed, so the admin page shows it), before
    # every attachment is checked against the index (design D-36; M4 review, #24).
    def crawl(limit: 200, seconds: nil)
      unless @tika.alive?
        raise TikaClient::Error.new("Tika does not answer (GET /tika at #{@tika.base_url}): nothing done", :unavailable)
      end

      missing = missing_ids
      todo = missing.first(limit)
      counts = new_counts
      deadline = seconds && Time.current + seconds
      failures = 0
      out_of_time = -> { deadline && Time.current > deadline }
      todo.each_slice(BATCH_SIZE) do |ids|
        break if out_of_time.call

        docs = []
        # the wiki of a wiki page's attachment is read for its project (RedmineDocuments.attachment_permissions): preloaded with the
        # container, so that it is not one query for each (M6 review, Gemini 2 1-3). Containers that have no wiki are left alone.
        batch = self.class.scope.where(id: ids).preload(container: :wiki).order(id: :desc).to_a
        RedmineDocuments.preload_issue_values(batch.map(&:container))
        batch.each do |attachment|
          break if out_of_time.call # each one may take up to Tika's timeout (M4 review, #18)

          result = extract(attachment)
          if result.status == :unavailable
            counts['deferred'] += 1
            failures += 1
            break if failures >= GIVE_UP_AFTER # not the rest of the batch either: each would wait for its timeout

            next
          end
          failures = 0
          docs << RedmineDocuments.attachment(attachment, result.text)
          tally(counts, result)
        end
        @client.add(docs)
        counts['sent'] += docs.size
        log "attachment: #{counts['sent']} sent, #{counts['deferred']} deferred"
        break if failures >= GIVE_UP_AFTER || out_of_time.call
      end
      counts['remaining'] = missing.size - counts['sent']
      {'attachment' => counts}
    end

    # Process 4 for attachments: every attachment in scope, newest first, the text made again (heavy: Tika is asked for
    # each). Removes nothing. Stops when Tika does not answer GIVE_UP_AFTER times in a row, like crawl (M4 review, #22).
    def reindex
      counts = new_counts
      failures = 0
      self.class.scope.preload(container: :wiki).find_in_batches(batch_size: BATCH_SIZE, order: :desc) do |attachments|
        RedmineDocuments.preload_issue_values(attachments.map(&:container))
        docs = []
        attachments.each do |attachment|
          result = extract(attachment)
          if result.status == :unavailable
            counts['deferred'] += 1
            failures += 1
            break if failures >= GIVE_UP_AFTER

            next
          end
          failures = 0
          docs << RedmineDocuments.attachment(attachment, result.text)
          tally(counts, result)
        end
        @client.add(docs)
        counts['sent'] += docs.size
        log "attachment: #{counts['sent']} sent"
        break if failures >= GIVE_UP_AFTER
      end
      {'attachment' => counts}
    end

    # Process 2 for attachments: what may have changed without the file changing, set in place (the file name and
    # description are edited after the upload; the permission values follow the container). The text is not touched, so
    # Tika is not asked. Only documents the index has: an update of a missing one would put it in the index without
    # text, so crawl would see it as already indexed and never extract its text (M4 review, #37).
    # Only the fields that changed, and nothing for an attachment where none did (M4 review, #7).
    # ids: only these attachments (the ones of a changed issue ...); default: every one in scope.
    def refresh(ids = nil)
      scope = ids ? self.class.scope.where(id: ids) : self.class.scope
      sent = 0
      scope.preload(container: :wiki).find_in_batches(batch_size: ID_SLICE) do |attachments|
        RedmineDocuments.preload_issue_values(attachments.map(&:container))
        stored = @client.get_docs(attachments.map {|a| "attachment-#{a.id}"}, fl: REFRESH_FIELDS)
        updates = attachments.filter_map do |a|
          doc = stored["attachment-#{a.id}"]
          RedmineDocuments.refresh_changes(RedmineDocuments.attachment_refresh(a), doc) if doc
        end
        @client.add(updates)
        sent += updates.size
        log "attachment: #{sent} refreshed"
      end
      {'attachment' => {'sent' => sent, 'deleted' => 0}}
    end

    private

    # The text, and one line in Redmine's log when there is none by a failure: the attachment, where it is attached, and
    # why. Not the file name: the id opens it (/attachments/<id>).
    def extract(attachment)
      result = @text.extract(attachment)
      if result.status == :unavailable && @tika.alive?
        result = AttachmentText::Result.new(status: :no_answer, message: "#{result.message}; Tika itself answers")
      end
      unless LEFT_OUT.include?(result.status)
        SolrSearch.log(:warn, "attachment #{attachment.id} (#{attachment.container_type} #{attachment.container_id}): " \
                              "no text, #{result.status}#{": #{result.message}" if result.message.present?}")
      end
      result
    end

    # The ids of the attachments in scope that the index does not have, newest first. Asks the index for the ids in
    # slices (a real-time get: one sent a moment ago counts as there).
    def missing_ids
      ids = self.class.scope.order(id: :desc).pluck(:id)
      ids.each_slice(ID_SLICE).flat_map do |slice|
        have = @client.existing_ids(slice.map {|id| "attachment-#{id}"}).to_set
        slice.reject {|id| have.include?("attachment-#{id}")}
      end
    end

    def new_counts
      {'sent' => 0, 'with_text' => 0, 'without_text' => Hash.new(0), 'deferred' => 0, 'deleted' => 0}
    end

    def tally(counts, result)
      if result.ok? && result.text.present?
        counts['with_text'] += 1
      else
        counts['without_text'][(result.ok? ? :empty : result.status).to_s] += 1
      end
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
