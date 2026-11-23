# frozen_string_literal: true

require_relative '../light_helper'

# The parts of the query for the issue custom fields (design D-31), from the fields a user may see. Which fields and
# projects a user gets from Redmine is checked on the seed data (docs/experiments/cf-d31).
class CustomFieldQueryTest < Minitest::Test
  Field = SolrSearch::CustomFieldQuery::Field

  def query(*fields)
    SolrSearch::CustomFieldQuery.new(fields)
  end

  def test_fields_for_all_join_the_main_clause
    q = query(Field.new(id: 6, project_ids: nil), Field.new(id: 8, project_ids: nil))
    assert_equal %w[cfj_6 cft_6 cfj_8 cft_8], q.main_fields(exact: false)
    assert_equal %w[cft_6 cft_8], q.main_fields(exact: true)
    assert_empty q.clauses(exact: false)
  end

  def test_fields_shown_to_some_roles_one_clause_per_set_of_projects
    q = query(Field.new(id: 5, project_ids: [1, 3]), Field.new(id: 7, project_ids: [2]),
              Field.new(id: 9, project_ids: [1, 3]), Field.new(id: 6, project_ids: nil))
    assert_equal %w[cfj_6 cft_6], q.main_fields(exact: false)
    assert_equal [["({!edismax qf=$cfqf0 v=$uq} AND {!terms f=project_id v='1,3'})", {cfqf0: 'cfj_5 cft_5 cfj_9 cft_9'}],
                  ["({!edismax qf=$cfqf1 v=$uq} AND {!terms f=project_id v='2'})", {cfqf1: 'cfj_7 cft_7'}]],
                 q.clauses(exact: false)
    assert_equal({cfqf0: 'cft_5 cft_9'}, q.clauses(exact: true).first.last)
  end

  def test_snippets_from_every_field
    q = query(Field.new(id: 5, project_ids: [1]), Field.new(id: 6, project_ids: nil))
    assert_equal %w[cft_5 cft_6], q.highlight_fields
  end

  def test_ids_must_be_integers
    assert_raises(ArgumentError) { query(Field.new(id: '5 OR x', project_ids: nil)).main_fields(exact: false) }
  end
end
