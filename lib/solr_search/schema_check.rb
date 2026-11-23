# frozen_string_literal: true

module SolrSearch
  # Whether a collection has the schema that the plugin expects of the collection of Redmine's data (design D-44): the
  # fields it writes and reads, by name and type, and the `required` marks that keep a document without its source out
  # (docs/schema.md). Pure: it is given what Schema API answered, so a light test checks it. The names of the types are
  # compared, not what their analyzers do, and solrconfig.xml is not looked at (a limit, said on the page).
  #
  # FIELDS is kept in step with solr/common/common-fields.xml and solr/configsets/redmine/conf/schema.xml by a light test.
  module SchemaCheck
    # field name => [type, required]
    FIELDS = {
      'id' => ['string', true],
      '_version_' => ['plong', false],
      'source' => ['string', true],
      'type' => ['string', true],
      'group_id' => ['string', true],
      'title' => ['rs_text_ngram', false],
      'content' => ['rs_text_ngram', false],
      'title_ja' => ['rs_text_ja', false],
      'content_ja' => ['rs_text_ja', false],
      'updated_at' => ['pdate', false],
      'project_id' => ['pint', false],
      'is_private' => ['boolean', false],
      'author_id' => ['pint', false],
      'assigned_to_id' => ['pint', false],
      'tracker_id' => ['pint', false],
      'status_id' => ['pint', false],
      'priority_id' => ['pint', false],
      'fixed_version_id' => ['pint', false],
      'category_id' => ['pint', false],
      'start_date' => ['pdate', false],
      'due_date' => ['pdate', false],
      'issue_created_at' => ['pdate', false],
      'issue_closed_at' => ['pdate', false],
      'file_extension' => ['string', false],
      'file_dir_1' => ['string', false],
      'file_dir_2' => ['string', false],
      'file_dir_3' => ['string', false],
      'file_dir_4' => ['string', false],
      'file_dir_5' => ['string', false],
      'file_dir_6' => ['string', false],
      'is_private_note' => ['boolean', false],
      'note_author_id' => ['pint', false],
      'container_type' => ['string', false],
      'item_id' => ['pint', false]
    }.freeze

    # the custom fields of issues (D-31): pattern => type
    DYNAMIC_FIELDS = {'cft_*' => 'rs_text_ngram', 'cfj_*' => 'rs_text_ja', 'cfs_*' => 'string', 'cfn_*' => 'pdouble',
                      'cfd_*' => 'pdate'}.freeze

    UNIQUE_KEY = 'id'

    # What the collection is made from: the configset of Redmine's data (design D-26)
    CONFIGSET = 'redmine'

    Problem = Struct.new(:kind, :name, :expected, :actual, keyword_init: true)

    module_function

    # schema: the "schema" object of Schema API's answer (name, uniqueKey, fields, dynamicFields ...).
    # Returns the problems; empty means that the schema is as expected.
    def check(schema)
      fields = (schema['fields'] || []).to_h {|field| [field['name'], field] }
      dynamic = (schema['dynamicFields'] || []).to_h {|field| [field['name'], field] }
      problems = []
      FIELDS.each do |name, (type, required)|
        field = fields[name]
        if field.nil?
          problems << Problem.new(kind: :missing_field, name: name, expected: type)
        elsif field['type'] != type
          problems << Problem.new(kind: :wrong_type, name: name, expected: type, actual: field['type'])
        elsif required && field['required'] != true
          problems << Problem.new(kind: :not_required, name: name)
        end
      end
      DYNAMIC_FIELDS.each do |name, type|
        field = dynamic[name]
        if field.nil?
          problems << Problem.new(kind: :missing_dynamic_field, name: name, expected: type)
        elsif field['type'] != type
          problems << Problem.new(kind: :wrong_dynamic_type, name: name, expected: type, actual: field['type'])
        end
      end
      if schema['uniqueKey'] != UNIQUE_KEY
        problems << Problem.new(kind: :wrong_unique_key, name: UNIQUE_KEY, actual: schema['uniqueKey'])
      end
      problems
    end

    # How many replicas to make the collection with: two (D-18), or one on a Solr of one node, where a second replica would
    # sit on the same node and protect nothing (O-28). A count that is not known: two.
    def replicas_for(live_nodes)
      live_nodes == 1 ? 1 : 2
    end

    # The command that an administrator runs to make the collection (design D-44): Collections API CREATE, one shard and
    # the replicas above, from the configset that solr/ holds (uploaded to Solr the way docker/solr-init does). base_url
    # and name were checked (SolrUrl allows only the characters of a host and a path, COLLECTION_NAME those of a name), so
    # they carry nothing that the shell would read; the whole address is in single quotes besides, for the & of the query.
    # Anything else is refused rather than written out (M6 review 4).
    def create_command(base_url, name, replicas: 2)
      raise ArgumentError, 'not a plain address' unless base_url.to_s.match?(%r{\A[A-Za-z0-9._~:/%+\[\]-]+\z})
      raise ArgumentError, 'not a collection name' unless name.to_s.match?(SolrSearch::COLLECTION_NAME)

      "curl '#{base_url}/admin/collections?action=CREATE&name=#{name}&numShards=1&replicationFactor=#{Integer(replicas)}" \
        "&collection.configName=#{CONFIGSET}'"
    end
  end
end
