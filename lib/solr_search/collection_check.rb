# frozen_string_literal: true

module SolrSearch
  # What is the state of the collection of Redmine's data at the Solr address (design D-44): does Solr answer, is the
  # collection there, and does it have the schema that the plugin expects. Read-only.
  module CollectionCheck
    # state: :ok, :unreachable (error says why), :missing (Solr answers, the collection is not there) or :schema
    # (it is there, and problems lists how its schema differs: SchemaCheck::Problem).
    # configset_present: for :missing, whether Solr has the configset to make it from (true, false, or nil: not known)
    # replicas: for :missing, how many replicas the command to make it asks for (SchemaCheck.replicas_for)
    Result = Struct.new(:state, :error, :problems, :configset_present, :replicas, keyword_init: true) do
      def ok?
        state == :ok
      end
    end

    module_function

    def call(client)
      unless client.collection_names.include?(client.collection)
        return Result.new(state: :missing, problems: [], configset_present: configset_present?(client),
                          replicas: SchemaCheck.replicas_for(live_node_count(client)))
      end

      problems = SchemaCheck.check(client.schema.fetch('schema'))
      problems.empty? ? Result.new(state: :ok, problems: []) : Result.new(state: :schema, problems: problems)
    rescue Client::Error => e
      Result.new(state: :unreachable, error: e.message, problems: [])
    end

    # nil when the nodes cannot be listed (an error): not known
    def live_node_count(client)
      client.live_nodes.size
    rescue Client::Error
      nil
    end

    # nil when the configsets cannot be listed (an error): not known
    def configset_present?(client)
      client.configset_names.include?(SchemaCheck::CONFIGSET)
    rescue Client::Error
      nil
    end
  end
end
