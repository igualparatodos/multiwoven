# frozen_string_literal: true

module Connectors
  class DiscoverConnector
    include Interactor

    def call
      context.catalog = context.connector.catalog
      # refresh catalog when the refresh flag is true
      return if context.catalog.present? && context.refresh != "true"

      catalog = context.connector.build_catalog(
        workspace_id: context.connector.workspace_id
      )

      catalog.catalog = streams(context.connector)
      catalog.catalog_hash = Digest::SHA1.hexdigest(catalog.catalog.to_s)
      catalog.save

      if catalog.persisted?
        context.catalog = catalog
      else
        context.fail!(catalog:)
      end
    end

    def connector_client(connector)
      @connector_client ||= Multiwoven::Integrations::Service.connector_class(
        connector.connector_type.camelize,
        connector.connector_name.camelize
      ).new
    end

    def streams(connector)
      @streams ||= begin
        catalog = connector_client(connector)
                  .discover(connector.resolved_configuration).catalog.to_h

        if connector.connector_type == "destination" && connector.connector_name == "Airtable"
          augment_airtable_metadata(catalog, connector)
        else
          catalog
        end
      end
    end

    private

    # Enrich Airtable catalog with x_airtable metadata for UI auto-inference
    # - Stream-level: x_airtable.table_id
    # - Field-level (in json_schema.properties): x_airtable.linked_table_id for link fields
    #   and linkage hints for lookups/rollups
    def augment_airtable_metadata(catalog, connector)
      config = connector.resolved_configuration.with_indifferent_access

      base_id = config["base_id"]
      api_key = config["api_key"]
      return catalog if base_id.blank? || api_key.blank?

      schema_url = Multiwoven::Integrations::Core::Constants::AIRTABLE_GET_BASE_SCHEMA_ENDPOINT.gsub("{baseId}", base_id)
      response = Multiwoven::Integrations::Core::HttpClient.request(
        schema_url,
        Multiwoven::Integrations::Core::Constants::HTTP_GET,
        headers: { "Authorization" => "Bearer #{api_key}" }
      )

      body = JSON.parse(response.body) rescue {}
      tables = (body["tables"] || [])

      (catalog[:streams] || []).each do |stream|
        table_id = extract_table_id_from_url(stream[:url])
        stream["x_airtable"] = { "table_id" => table_id }
        next if table_id.blank?

        table = tables.find { |t| t["id"] == table_id }
        next unless table

        properties = stream.dig(:json_schema, "properties")
        next unless properties.is_a?(Hash)

        table_fields = table["fields"] || []

        table_fields.each do |field|
          key = clean_name(field["name"].to_s)
          next unless properties[key].is_a?(Hash)
          type = field["type"]
          options = field["options"] || {}
          case type
          when "multipleRecordLinks"
            linked_table_id = options["linkedTableId"]
            properties[key]["x_airtable"] = { "linked_table_id" => linked_table_id } if linked_table_id
          when "multipleLookupValues", "lookup", "rollup"
            meta = {}
            meta["via_record_link_field_id"] = options["recordLinkFieldId"] if options["recordLinkFieldId"]
            meta["field_in_linked_table"] = options["fieldIdInLinkedTable"] if options["fieldIdInLinkedTable"]
            properties[key]["x_airtable"] = meta if meta.any?
          end
        end
      end

      catalog
    rescue StandardError => e
      Rails.logger.error({
        error_message: e.message,
        stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
      }.to_s)
      catalog
    end

    def extract_table_id_from_url(url)
      return nil if url.blank?
      parts = url.to_s.split("/")
      parts.last
    end

    def clean_name(name_str)
      name_str.strip.gsub(" ", "_")
    end
  end
end
