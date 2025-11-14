# frozen_string_literal: true

require_relative "link_resolver"

module ReverseEtl
  module Transformers
    module DestinationHandlers
      module Airtable
        class Handler < Base
          # Transforms custom mapping for Airtable linked records
          # @param mapping [Hash] The mapping configuration with options
          # @param record [Hash] The source record being transformed
          # @param context [Hash] Additional context (sync, preload_indexes, etc.)
          # @return [Array<String>, nil] Resolved Airtable record IDs or nil
          def self.transform_custom_mapping(mapping, record, context = {})
            options = (mapping[:options] || {}).with_indifferent_access
            source_value = record[mapping[:from]]
            return nil if source_value.blank?

            # Resolve credentials/defaults from destination connector if not provided
            sync = context[:sync]
            destination = sync&.destination || Thread.current[:current_sync_destination]
            destination_config = destination&.resolved_configuration || {}

            linked_table_id = options[:linked_table_id]
            match_field = options[:match_field]

            return nil unless linked_table_id.present? && match_field.present?

            # Use preload_indexes from context if available
            preload_indexes = context[:preload_indexes] || {}
            cache_key = [linked_table_id, match_field].join(":")
            value_index = preload_indexes[cache_key]

            return nil unless value_index

            values = source_value.is_a?(Array) ? source_value : [source_value]
            id_map = values.each_with_object({}) { |v, h| h[v] = value_index[v] || [] }

            # Collect resolved IDs, ignore values with no matches
            resolved_ids = values.flat_map { |v| id_map[v] || [] }.uniq

            return nil if resolved_ids.empty?

            resolved_ids
          end

          # Builds preload indexes for Airtable linked records
          # @param sync [Sync] The sync object
          # @param mappings [Array] Array of mapping configurations
          # @return [Hash] Hash of preload indexes keyed by cache key
          def self.build_custom_mapping_indexes(sync, mappings)
            mappings = mappings.is_a?(Array) ? mappings : []
            link_mappings = mappings.select { |m| m.is_a?(Hash) && m["mapping_type"] == "custom_mapping" }
            return {} if link_mappings.empty?

            destination = sync.destination
            destination_config = destination&.resolved_configuration || {}
            base_id = destination_config["base_id"]
            api_key = destination_config["api_key"]
            return {} unless base_id.present? && api_key.present?

            # Determine distinct (linked_table_id, match_field) pairs
            pairs = link_mappings.map { |m| [m.dig("options", "linked_table_id"), m.dig("options", "match_field")] }
                                  .select { |lt, mf| lt.present? && mf.present? }
                                  .uniq
            return {} if pairs.empty?

            resolver = LinkResolver.new(api_key:, base_id:)
            index = {}
            pairs.each do |linked_table_id, match_field|
              key = [linked_table_id, match_field].join(":")
              index[key] = resolver.build_full_index(linked_table_id:, match_field:)
            end

            index
          rescue StandardError => e
            Rails.logger.error({
              error_message: e.message,
              context: "Airtable::Handler.build_custom_mapping_indexes",
              stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
            }.to_s)
            {}
          end
        end
      end
    end
  end
end
