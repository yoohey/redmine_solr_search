# frozen_string_literal: true

module SolrSearch
  # Turns Redmine records into documents of the "redmine" collection. The mapping is the contract written in
  # docs/schema.md, section 3.1; change both together.
  # A container's values (an issue's subject ...) are never copied into its items (journals ...): every item would
  # then match on them, whatever its own text (design D-27).
  module RedmineDocuments
    module_function

    def issue(issue)
      document(
        id: "issue-#{issue.id}",
        type: 'issue',
        group_id: "issue-#{issue.id}",
        title: issue.subject,
        content: issue.description,
        updated_at: issue.updated_on,
        item_id: issue.id,
        **issue_permissions(issue),
        **issue_values(issue),
        **custom_field_texts(issue)
      )
    end

    # Custom field formats with text to search (D-31): the ones Redmine lets be "searchable" (searchable_supported)
    CUSTOM_FIELD_TEXT_FORMATS = %w[string text list].freeze

    # {"cft_12" => [values]}: every text custom field the issue has (its tracker and project decide which; Redmine's
    # custom_field_values), searchable or not; the search side picks the searchable ones the user may see (D-31)
    def custom_field_texts(issue)
      custom_field_pairs(issue).each_with_object({}) do |(field, value), fields|
        next unless CUSTOM_FIELD_TEXT_FORMATS.include?(field.field_format)

        values = Array(value).map(&:to_s).reject(&:empty?)
        fields[:"cft_#{field.id}"] = values if values.any?
      end
    end

    # [[custom field, value], ...] for the custom fields an issue has (its project and its tracker decide which, as in Redmine's
    # Issue#available_custom_fields): what Redmine's custom_field_values gives, without building a CustomFieldValue and, for each
    # field with no value, a CustomValue: that was most of the time of a reindex (0.7 ms an issue with five fields; Q-38, docs/experiments/m7-reindex).
    # The value is the stored one (nil: none; the first if there are several of a field with one value), and a list of them for a
    # field with several values. A value stored for a field that the issue no longer has is not there, as in Redmine. For an issue that is
    # saved (the only ones indexed) Redmine does not put the default value of a field in a field with no value.
    def custom_field_pairs(issue)
      stored = issue.custom_values.group_by(&:custom_field_id)
      issue.available_custom_fields.map do |field|
        values = stored.fetch(field.id, [])
        [field, field.multiple? ? values.map(&:value) : values.first&.value]
      end
    end

    # A note on an issue. It carries the issue's permission values (design D-27, D-30) and its own: whether it is a
    # private note, and who wrote it (not the issue's author).
    def journal(journal)
      document(
        id: "journal-#{journal.id}",
        type: 'journal',
        group_id: "issue-#{journal.journalized_id}",
        content: journal.notes,
        updated_at: journal.updated_on,
        item_id: journal.id,
        is_private_note: journal.private_notes,
        note_author_id: journal.user_id,
        **issue_permissions(journal.issue),
        **issue_values(journal.issue)
      )
    end

    # What Redmine's Issue.visible_condition looks at, on the issue's side (design D-30)
    def issue_permissions(issue)
      {project_id: issue.project_id, is_private: issue.is_private, author_id: issue.author_id,
       assigned_to_id: issue.assigned_to_id, tracker_id: issue.tracker_id}
    end

    # More values of the issue, for the facets and choices of the search screen (D-49): on the issue and on each of its notes
    # and attachments, like the permission values, so that a choice keeps the container whole
    ISSUE_VALUE_KEYS = %i[status_id priority_id fixed_version_id category_id start_date due_date issue_created_at issue_closed_at].freeze

    def issue_values(issue)
      {status_id: issue.status_id, priority_id: issue.priority_id, fixed_version_id: issue.fixed_version_id,
       category_id: issue.category_id, start_date: date_time(issue.start_date), due_date: date_time(issue.due_date),
       issue_created_at: utc(issue.created_on), issue_closed_at: utc(issue.closed_on), **custom_field_facet_values(issue)}
    end

    # Reads what issue_values asks of the issues of a batch at once (a record at a time it is a few queries each): the custom
    # values, and the project and tracker that decide which custom fields an issue has
    def preload_issue_values(issues)
      issues = issues.select {|issue| issue.is_a?(Issue) }
      return if issues.empty?

      associations = %i[project tracker custom_values]
      # Rails 7.0 changed how the preloader is called; Redmine 5.1 runs Rails 6.1 (design D-62)
      if ActiveRecord.version >= Gem::Version.new('7.0')
        ActiveRecord::Associations::Preloader.new(records: issues, associations: associations).call
      else
        ActiveRecord::Associations::Preloader.new.preload(issues, associations)
      end
    end

    # The custom fields that are used as a filter ("is_filter": Redmine's own choice of what a list of issues can be narrowed
    # by) and have a value to count or to choose by (D-49): cfs_<id> the values of a list, a boolean, a key/value list, a user
    # or a version (an id for the last three); cfn_<id> a number; cfd_<id> a date. The text ones are searched, not counted.
    CUSTOM_FIELD_FACET_FORMATS = %w[list bool enumeration user version int float date].freeze

    def custom_field_facet_values(issue)
      # the notes of one issue (the same object within a batch) ask for it once each: made once for the issue
      issue.instance_variable_get(:@solr_search_facet_values) || issue.instance_variable_set(:@solr_search_facet_values, facet_values_of(issue))
    end

    def facet_values_of(issue)
      custom_field_pairs(issue).each_with_object({}) do |(custom_field, value), fields|
        next unless custom_field.is_filter? && CUSTOM_FIELD_FACET_FORMATS.include?(custom_field.field_format)

        values = Array(value).map(&:to_s).reject(&:empty?)
        next if values.empty?

        case custom_field.field_format
        when 'int', 'float'
          number = Float(values.first, exception: false)
          fields[:"cfn_#{custom_field.id}"] = number if number
        when 'date'
          date = Date.iso8601(values.first) rescue nil
          fields[:"cfd_#{custom_field.id}"] = "#{date.iso8601}T00:00:00Z" if date
        else
          fields[:"cfs_#{custom_field.id}"] = values
        end
      end
    end

    # A wiki page with the text of its latest version.
    def wiki_page(page)
      content = page.content
      document(
        id: "wiki_page-#{page.id}",
        type: 'wiki_page',
        group_id: "wiki_page-#{page.id}",
        title: page.title,
        content: content&.text,
        updated_at: content&.updated_on,
        project_id: page.wiki.project_id,
        is_private: false,
        item_id: page.id
      )
    end

    # documents has no updated_on: edits are picked up by resending every document (design D-22, process 2).
    def document_record(doc)
      document(
        id: "document-#{doc.id}",
        type: 'document',
        group_id: "document-#{doc.id}",
        title: doc.title,
        content: doc.description,
        updated_at: doc.created_on,
        project_id: doc.project_id,
        is_private: false,
        item_id: doc.id
      )
    end

    # What an attachment can be attached to, in the index (design D-36): Redmine's container_type => container_type of the
    # document; the container's group id is "<that>-<id>". The attachments of news, forum messages and the like are not
    # indexed. A version's attachments are the "Files" module's, like the project's.
    ATTACHMENT_CONTAINERS = {
      'Issue' => 'issue', 'WikiPage' => 'wiki_page', 'Document' => 'document', 'Project' => 'project',
      'Version' => 'version'
    }.freeze

    # An attachment (design D-36). text: what Tika made of the file, or nil: then the document still has the file name
    # and the description. It is a record of its own, in the group of what it is attached to, and carries the permission
    # values of that (an issue's, like a note).
    def attachment(attachment, text = nil)
      kind = ATTACHMENT_CONTAINERS.fetch(attachment.container_type)
      document(
        id: "attachment-#{attachment.id}",
        type: 'attachment',
        container_type: kind,
        group_id: "#{kind}-#{attachment.container_id}",
        title: attachment_title(attachment),
        content: text,
        updated_at: attachment.created_on,
        item_id: attachment.id,
        file_extension: File.extname(attachment.filename.to_s).delete_prefix('.'), # as written; a file without one has none (D-49)
        **attachment_permissions(kind, attachment.container)
      )
    end

    # The file name, and the description after it (what the person who attached it said about it)
    def attachment_title(attachment)
      [attachment.filename, attachment.description.presence].compact.join(' ')
    end

    # What the permission filter reads of an attachment: the project (a wiki page's through its wiki; a version's is its
    # own project's, as in Redmine's Version#attachments_visible?), and for an issue's attachment the issue's values
    def attachment_permissions(kind, container)
      case kind
      when 'issue' then issue_permissions(container).merge(issue_values(container))
      when 'wiki_page' then {project_id: container.wiki.project_id, is_private: false}
      when 'project' then {project_id: container.id, is_private: false}
      else {project_id: container.project_id, is_private: false} # document, version
      end
    end

    # An atomic update of what changes without the file changing (design D-36, D-22): the file name and description (edited
    # after the upload) and the container's permission values. The text is not touched, so Tika is not asked again.
    # Only for a document that is in the index: an update of a missing document would put it in the index without text,
    # so crawl would see it as already indexed and never extract its text (M4 review, #37).
    def attachment_refresh(attachment)
      fields = attachment(attachment) # without text: the same fields, and the document() rules for them
      fields.except(:id, :content).transform_values {|v| {set: v}}.merge(id: fields[:id]).tap do |update|
        # a value the container no longer has (an issue no longer assigned) is removed, not left as it was
        (%i[assigned_to_id author_id tracker_id] + ISSUE_VALUE_KEYS).each {|key| update[key] ||= {set: nil}}
      end
    end

    # The update with only the fields whose value differs from the stored one (stored: the document as the index has it,
    # with string keys), or nil when none does. An atomic update makes Solr index the whole document again, its long text
    # included: an attachment nothing changed in is not sent (M4 review, #7).
    def refresh_changes(update, stored)
      # a custom field value that the issue no longer has (its field is no longer a filter, or the value was removed) goes too
      stale = stored.keys.grep(/\Acf[snd]_\d+\z/).reject {|key| update.key?(key.to_sym)}.to_h {|key| [key.to_sym, {set: nil}]}
      changed = update.except(:id).merge(stale).reject {|key, op| stored[key.to_s] == op[:set]}
      changed.empty? ? nil : changed.merge(id: update[:id])
    end

    # C0 control characters but tab, newline and carriage return. Two of them mark the snippets (Searcher::HL_PRE,
    # HL_POST); in the text they would break the snippet's HTML (M1 review A7). The others mean nothing in a search.
    CONTROL_CHARACTERS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/

    # Drops empty values (Solr needs no field for them) and control characters from the text fields (title, content,
    # custom fields), and adds the fields every document has.
    def document(fields)
      fields = fields.merge(source: SOURCE, updated_at: utc(fields[:updated_at]))
      fields = fields.to_h {|key, v| [key, %i[title content].include?(key) || key.start_with?('cft_', 'cfs_') ? clean(v) : v]}
      fields.reject {|_, v| v.nil? || v == '' || v == []}
    end

    def clean(value)
      case value
      when String then value.gsub(CONTROL_CHARACTERS, '')
      when Array then value.map {|v| clean(v)}
      else value
      end
    end

    # A date as Solr's pdate: the midnight UTC of it
    def date_time(date)
      "#{date.iso8601}T00:00:00Z" if date
    end

    # Solr's pdate is UTC. Redmine stores local time (default_timezone = :local), and Active Record returns it
    # with the zone, so converting here is enough (docs/schema.md 3.1).
    def utc(time)
      time&.utc&.iso8601
    end
  end
end
