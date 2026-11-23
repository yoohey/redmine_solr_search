# frozen_string_literal: true

require_relative '../light_helper'

# What every document sent to Solr gets (docs/schema.md 3.1; M1 review A7)
class RedmineDocumentsTest < Minitest::Test
  def document(fields)
    SolrSearch::RedmineDocuments.document(fields)
  end

  def test_source_and_utc_time
    local = Time.new(2026, 9, 29, 21, 30, 5, '+09:00') # Redmine stores local time (default_timezone = :local)
    doc = document(id: 'issue-1', type: 'issue', title: '件名', updated_at: local)
    assert_equal SolrSearch::SOURCE, doc[:source]
    assert_equal '2026-09-29T12:30:05Z', doc[:updated_at]
  end

  def test_utc_of_nothing
    assert_nil SolrSearch::RedmineDocuments.utc(nil)
    refute document(id: 'wiki_page-1', updated_at: nil).key?(:updated_at)
  end

  def test_control_characters_removed_but_tab_newline_and_return
    doc = document(id: 'issue-1', title: "a\u0002b\u0003c", content: "x\ty\nz\r\u0000\u001F!")
    assert_equal 'abc', doc[:title]
    assert_equal "x\ty\nz\r!", doc[:content]
  end

  def test_custom_field_values_cleaned_and_empty_ones_dropped
    doc = document(id: 'issue-1', cft_5: ["a\u0002b", 'c'], cft_6: [], cft_7: ['x'])
    assert_equal %w[ab c], doc[:cft_5]
    refute doc.key?(:cft_6)
    assert_equal %w[x], doc[:cft_7]
  end

  def test_empty_values_dropped
    doc = document(id: 'document-1', title: 'T', content: '', item_id: 1, is_private: false)
    refute doc.key?(:content)
    assert_equal false, doc[:is_private] # false is a value, not an empty one
  end
end

# Attachments (design D-36)
class AttachmentDocumentsTest < Minitest::Test
  RD = SolrSearch::RedmineDocuments
  Att = Struct.new(:id, :container_type, :container_id, :container, :filename, :description, :created_on, keyword_init: true)
  Issue = Struct.new(:project_id, :is_private, :author_id, :assigned_to_id, :tracker_id, :status_id, :priority_id, :fixed_version_id,
                     :category_id, :start_date, :due_date, :created_on, :closed_on, :custom_values, :available_custom_fields, keyword_init: true) do
    def custom_values
      self[:custom_values] || []
    end

    def available_custom_fields
      self[:available_custom_fields] || []
    end
  end
  Wiki = Struct.new(:project_id)
  Page = Struct.new(:wiki)
  Doc = Struct.new(:project_id)
  Proj = Struct.new(:id)
  Ver = Struct.new(:project_id)
  T = Time.utc(2026, 10, 6, 1, 2, 3)

  def att(type, id, container, description: nil)
    Att.new(id: 7, container_type: type, container_id: id, container: container, filename: '議事録.pdf', description: description, created_on: T)
  end

  def test_an_issues_attachment_has_the_issues_permission_values
    issue = Issue.new(project_id: 3, is_private: true, author_id: 5, assigned_to_id: nil, tracker_id: 2, status_id: 1, priority_id: 4,
                      fixed_version_id: nil, category_id: 9, start_date: Date.new(2026, 10, 1), due_date: nil,
                      created_on: Time.utc(2026, 9, 30, 15, 0, 0), closed_on: nil)
    doc = RD.attachment(att('Issue', 12, issue), '本文')
    assert_equal({id: 'attachment-7', type: 'attachment', container_type: 'issue', group_id: 'issue-12', title: '議事録.pdf',
                  content: '本文', updated_at: '2026-10-06T01:02:03Z', item_id: 7, file_extension: 'pdf', source: 'redmine', project_id: 3,
                  is_private: true, author_id: 5, tracker_id: 2, status_id: 1, priority_id: 4, category_id: 9, start_date: '2026-10-01T00:00:00Z',
                  issue_created_at: '2026-09-30T15:00:00Z'}, doc) # no version, no due date, not closed: no field
  end

  def test_the_other_containers
    {[ 'WikiPage', 4, Page.new(Wiki.new(8))] => ['wiki_page', 'wiki_page-4', 8],
     ['Document', 5, Doc.new(9)] => ['document', 'document-5', 9],
     ['Project', 6, Proj.new(10)] => ['project', 'project-6', 10],
     ['Version', 7, Ver.new(11)] => ['version', 'version-7', 11]}.each do |(type, id, container), (kind, group, project)|
      doc = RD.attachment(att(type, id, container))
      assert_equal [kind, group, project, false], [doc[:container_type], doc[:group_id], doc[:project_id], doc[:is_private]], type
      refute doc.key?(:content) # no text: file name and description only
      refute doc.key?(:author_id) # only an issue's attachment has the issue's values
    end
  end

  def test_the_description_follows_the_file_name_in_the_title
    doc = RD.attachment(att('Document', 5, Doc.new(9), description: '第3回の議事録'))
    assert_equal '議事録.pdf 第3回の議事録', doc[:title]
  end

  def test_a_container_of_a_kind_that_is_not_indexed_is_an_error_not_a_guess
    assert_raises(KeyError) { RD.attachment(att('News', 1, nil)) }
  end

  def test_a_refresh_sets_what_may_have_changed_and_leaves_the_text
    issue = Issue.new(project_id: 3, is_private: false, author_id: 5, assigned_to_id: nil, tracker_id: 2)
    update = RD.attachment_refresh(att('Issue', 12, issue, description: 'd'))
    assert_equal 'attachment-7', update[:id]
    assert_equal({set: '議事録.pdf d'}, update[:title])
    assert_equal({set: 3}, update[:project_id])
    assert_equal({set: nil}, update[:assigned_to_id]) # no longer assigned: removed
    assert_equal({set: nil}, update[:fixed_version_id]) # no target version: removed
    assert_equal({set: nil}, update[:issue_closed_at]) # not closed: removed
    refute update.key?(:content)
    assert(update.except(:id).values.all? {|v| v.is_a?(Hash) && v.keys == [:set] }, 'every field but id is a {set: ...}')
  end

  # M4 review, #7: what the index already has is not sent again (Solr would index the whole document, its text included)
  def test_a_refresh_sends_only_what_differs_from_the_index
    issue = Issue.new(project_id: 3, is_private: false, author_id: 5, assigned_to_id: nil, tracker_id: 2)
    update = RD.attachment_refresh(att('Issue', 12, issue, description: 'd'))
    stored = update.except(:id).to_h {|key, op| [key.to_s, op[:set]]}.compact.merge('id' => 'attachment-7')
    assert_nil RD.refresh_changes(update, stored), 'nothing changed: nothing to send'

    changed = RD.refresh_changes(update, stored.merge('title' => '議事録.pdf', 'assigned_to_id' => 4))
    assert_equal %i[assigned_to_id id title], changed.keys.sort
    assert_equal({set: '議事録.pdf d'}, changed[:title])
    assert_equal({set: nil}, changed[:assigned_to_id]) # the index still has the one no longer assigned

    assert_equal({set: 3}, RD.refresh_changes(update, stored.except('project_id'))[:project_id]) # missing in the index
  end
end

# The issue custom fields used as a filter (D-49), and the values of the fields of an issue (Q-38)
class CustomFieldFacetValuesTest < Minitest::Test
  RD = SolrSearch::RedmineDocuments
  Field = Struct.new(:id, :field_format, :is_filter, :multiple) do
    alias_method :is_filter?, :is_filter
    alias_method :multiple?, :multiple
  end
  Stored = Struct.new(:custom_field_id, :value)
  Value = Struct.new(:custom_field, :value)
  Issue = Struct.new(:custom_values, :available_custom_fields)

  # an issue with the fields and the stored values that the pairs (field, value) say; a list value is one stored value each
  def issue(*pairs)
    stored = pairs.flat_map {|v| Array(v.value).map {|x| Stored.new(v.custom_field.id, x) } }
    Issue.new(stored, pairs.map {|v| v.custom_field.tap {|f| f.multiple = v.value.is_a?(Array) } })
  end

  def values(*cfvs)
    RD.custom_field_facet_values(issue(*cfvs))
  end

  def test_each_format_goes_to_its_own_kind_of_field
    got = values(Value.new(Field.new(4, 'list', true), %w[A B]), Value.new(Field.new(5, 'bool', true), '1'),
                 Value.new(Field.new(6, 'user', true), '7'), Value.new(Field.new(7, 'int', true), '120'),
                 Value.new(Field.new(8, 'float', true), '1.5'), Value.new(Field.new(9, 'date', true), '2026-10-20'))
    assert_equal({cfs_4: %w[A B], cfs_5: ['1'], cfs_6: ['7'], cfn_7: 120.0, cfn_8: 1.5, cfd_9: '2026-10-20T00:00:00Z'}, got)
  end

  def test_only_the_fields_used_as_a_filter_and_with_a_value
    got = values(Value.new(Field.new(1, 'list', false), 'A'), Value.new(Field.new(2, 'list', true), ['', nil]),
                 Value.new(Field.new(3, 'string', true), 'text'), Value.new(Field.new(4, 'int', true), 'not a number'),
                 Value.new(Field.new(5, 'date', true), 'tomorrow'))
    assert_empty got # not a filter; no value; a text field (searched, not counted); a number and a date that are not
  end

  def test_the_fields_of_an_issue_are_those_that_it_has_with_the_stored_value_or_none
    list = Field.new(1, 'list', true, true)
    text = Field.new(2, 'string', false, false)
    other = Field.new(3, 'string', false, false)
    stored = [Stored.new(1, 'A'), Stored.new(1, 'B'), Stored.new(2, 'first'), Stored.new(2, 'second'), Stored.new(9, 'of a field it has no more')]
    pairs = RD.custom_field_pairs(Issue.new(stored, [list, text, other]))
    assert_equal [[list, %w[A B]], [text, 'first'], [other, nil]], pairs
    assert_equal [[list, []]], RD.custom_field_pairs(Issue.new([], [list])), 'a list with no value is an empty list'
    assert_empty RD.custom_field_pairs(Issue.new(stored, [])), 'no field: nothing, whatever is stored'
  end

  def test_the_texts_are_those_of_the_text_fields
    text = Field.new(2, 'string', false, false)
    lst = Field.new(3, 'list', false, true)
    none = Field.new(4, 'text', false, false)
    num = Field.new(5, 'int', true, false)
    issue = Issue.new([Stored.new(2, 'a b'), Stored.new(3, 'X'), Stored.new(3, 'Y'), Stored.new(5, '7')], [text, lst, none, num])
    assert_equal({cft_2: ['a b'], cft_3: %w[X Y]}, RD.custom_field_texts(issue)) # the number is not a text; the field with no value is left out
  end

  def test_a_refresh_takes_off_a_custom_field_value_that_the_issue_no_longer_has
    update = {id: 'attachment-7', title: {set: 'a'}}
    stored = {'id' => 'attachment-7', 'title' => 'a', 'cfs_4' => ['A'], 'cfn_7' => 3.0, 'tracker_id' => 1}
    changed = RD.refresh_changes(update, stored)
    assert_equal({id: 'attachment-7', cfs_4: {set: nil}, cfn_7: {set: nil}}, changed) # not the fields that are not custom fields
  end

  def test_the_value_of_a_list_is_cleaned_of_control_characters
    doc = RD.document(id: 'issue-1', cfs_4: ["a\u0002b"])
    assert_equal %w[ab], doc[:cfs_4]
  end
end

