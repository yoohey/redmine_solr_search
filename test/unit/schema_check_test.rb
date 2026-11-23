# frozen_string_literal: true

require_relative '../light_helper'

# The schema that the plugin expects of the collection of Redmine's data (design D-44)
class SchemaCheckTest < Minitest::Test
  C = SolrSearch::SchemaCheck
  ROOT = File.expand_path('../..', __dir__)

  # what Schema API answers for a schema as expected
  def good_schema
    {
      'uniqueKey' => 'id',
      'fields' => C::FIELDS.map {|name, (type, required)| {'name' => name, 'type' => type}.merge(required ? {'required' => true} : {}) },
      'dynamicFields' => C::DYNAMIC_FIELDS.map {|name, type| {'name' => name, 'type' => type} }
    }
  end

  def kinds(schema)
    C.check(schema).map {|p| [p.kind, p.name] }
  end

  def test_the_expected_schema_has_no_problem
    assert_empty C.check(good_schema)
  end

  def test_a_missing_field_is_named
    schema = good_schema
    schema['fields'].reject! {|f| f['name'] == 'group_id' }
    assert_equal [[:missing_field, 'group_id']], kinds(schema)
  end

  def test_a_field_of_another_type_is_named_with_both_types
    schema = good_schema
    schema['fields'].find {|f| f['name'] == 'project_id' }['type'] = 'string'
    problem = C.check(schema).first
    assert_equal [:wrong_type, 'project_id', 'pint', 'string'], [problem.kind, problem.name, problem.expected, problem.actual]
  end

  def test_source_type_group_id_and_id_must_be_required
    schema = good_schema
    schema['fields'].find {|f| f['name'] == 'source' }.delete('required')
    assert_equal [[:not_required, 'source']], kinds(schema)
  end

  def test_a_missing_dynamic_field_and_a_wrong_one
    schema = good_schema
    schema['dynamicFields'].reject! {|f| f['name'] == 'cft_*' }
    schema['dynamicFields'].find {|f| f['name'] == 'cfj_*' }['type'] = 'string'
    assert_equal [[:missing_dynamic_field, 'cft_*'], [:wrong_dynamic_type, 'cfj_*']], kinds(schema)
  end

  def test_the_unique_key_must_be_id
    schema = good_schema.merge('uniqueKey' => 'doc_id')
    assert_equal [[:wrong_unique_key, 'id']], kinds(schema)
  end

  def test_an_empty_answer_misses_everything
    assert_equal C::FIELDS.size + C::DYNAMIC_FIELDS.size + 1, C.check({}).size
  end

  def test_extra_fields_are_no_problem
    schema = good_schema
    schema['fields'] << {'name' => 'mine', 'type' => 'string'}
    assert_empty C.check(schema)
  end

  def test_the_create_command_has_the_address_the_name_and_the_configset
    command = C.create_command('http://solr-lb/solr', 'redmine_prod')
    assert_includes command, 'http://solr-lb/solr/admin/collections?action=CREATE&name=redmine_prod'
    assert_includes command, 'numShards=1&replicationFactor=2&collection.configName=redmine'
  end

  def test_one_replica_on_a_solr_of_one_node_and_two_otherwise
    assert_equal 1, C.replicas_for(1)
    assert_equal 2, C.replicas_for(2)
    assert_equal 2, C.replicas_for(3)
    assert_equal 2, C.replicas_for(nil)
    assert_includes C.create_command('http://solr-lb/solr', 'redmine', replicas: 1), 'replicationFactor=1&'
  end

  # what CollectionCheck needs of the client when the collection is not there
  FakeClient = Struct.new(:nodes) do
    def collection; 'redmine'; end
    def collection_names; []; end
    def configset_names; ['redmine']; end

    def live_nodes
      nodes || raise(SolrSearch::Client::Error, 'no answer')
    end
  end

  def test_a_missing_collection_is_told_the_replicas_by_the_nodes_that_are_up
    assert_equal 1, SolrSearch::CollectionCheck.call(FakeClient.new(['a'])).replicas
    assert_equal 2, SolrSearch::CollectionCheck.call(FakeClient.new(%w[a b])).replicas
    result = SolrSearch::CollectionCheck.call(FakeClient.new(nil))
    assert_equal :missing, result.state
    assert_equal 2, result.replicas
  end

  def test_the_create_command_is_in_single_quotes_and_refuses_what_the_shell_would_read
    assert_match(/\Acurl '.*'\z/, C.create_command('http://solr-lb/solr', 'redmine_prod'))
    assert_raises(ArgumentError) { C.create_command('http://h/$(id)', 'redmine') }
    assert_raises(ArgumentError) { C.create_command("http://h/solr'; ls '", 'redmine') }
    assert_raises(ArgumentError) { C.create_command('http://h/solr', 'a b') }
    assert_raises(ArgumentError) { C.create_command('http://h/solr', "x'; ls") }
  end

  # FIELDS is a copy of what solr/ defines: the two must not drift apart (the test reads the definition files)
  def test_the_list_is_the_one_of_the_schema_files_of_the_repository
    xml = File.read(File.join(ROOT, 'solr/common/common-fields.xml')) + File.read(File.join(ROOT, 'solr/configsets/redmine/conf/schema.xml'))
    defined = {}
    xml.scan(/<field\s+name="([^"]+)"\s+type="([^"]+)"([^>]*)\/>/) {|name, type, rest| defined[name] = [type, rest.include?('required="true"')] }
    assert_equal defined, C::FIELDS, 'solr/ and SolrSearch::SchemaCheck::FIELDS differ: change both'
    dynamic = {}
    xml.scan(/<dynamicField\s+name="([^"]+)"\s+type="([^"]+)"/) {|name, type| dynamic[name] = type }
    assert_equal dynamic, C::DYNAMIC_FIELDS
    assert_equal C::UNIQUE_KEY, xml[/<uniqueKey>([^<]+)<\/uniqueKey>/, 1]
  end
end
