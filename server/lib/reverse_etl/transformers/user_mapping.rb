# frozen_string_literal: true

require_relative "destination_handlers/registry"

module ReverseEtl
  module Transformers
    class UserMapping < Base
      attr_accessor :mappings, :record, :destination_data, :preload_indexes, :destination_schema

      def transform(sync, sync_record)
        @mappings = sync.configuration
        @record = sync_record.record
        @destination_data = {}
        @sync = sync
        @preload_indexes = preload_indexes || {}
        @destination_schema ||= fetch_destination_schema(sync)
        @destination_schema_properties ||= extract_schema_properties(@destination_schema)

        if mappings.is_a?(Array)
          transform_record_v2
        else
          transform_record_v1
        end

        apply_destination_schema!(@destination_data, @destination_schema_properties)
        @destination_data
      rescue StandardError => e
        # Utils::ExceptionReporter.report(e, {
        #                                   sync_id: sync.id,
        #                                   sync_record_id: sync_record.id
        #                                 })
        Rails.logger.error({
          error_message: e.message,
          sync_id: sync.id,
          stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
        }.to_s)
      end

      private

      def transform_record_v1
        mappings.each do |source_key, dest_path|
          dest_keys = dest_path.split(".")
          mapped_destination_value = record[source_key]
          extract_destination_mapping(dest_keys, mapped_destination_value)
        end
      end

      def transform_record_v2
        mappings.each do |mapping|
          mapping = mapping.with_indifferent_access
          case mapping[:mapping_type]
          when "standard"
            standard_mapping(mapping)
          when "static"
            static_mapping(mapping)
          when "template"
            template_mapping(mapping)
          when "vector"
            vector_mapping(mapping)
          when "custom_mapping"
            custom_mapping(mapping)
          end
        end
      end

      def vector_mapping(mapping)
        dest_keys = mapping[:to].split(".")
        source_key = mapping[:from]
        embedding_config = mapping[:embedding_config]
        mapped_destination_value = if embedding_config
                                     ReverseEtl::Transformers::Embeddings::EmbeddingService
                                       .new(embedding_config:).generate_embedding(record[source_key])
                                   else
                                     record[source_key]
                                   end

        extract_destination_mapping(dest_keys, mapped_destination_value)
      end

      def standard_mapping(mapping)
        dest_keys = mapping[:to].split(".")
        source_key = mapping[:from]

        mapped_destination_value = record[source_key]

        sanitized_mapped_value = if mapped_destination_value.is_a?(String)
                                   mapped_destination_value.gsub("'", "''")
                                 else
                                   mapped_destination_value
                                 end

        extract_destination_mapping(dest_keys, sanitized_mapped_value)
      end

      def static_mapping(mapping)
        dest_keys = mapping[:to].split(".")
        static_value = mapping[:from]
        extract_destination_mapping(dest_keys, static_value)
      end

      def template_mapping(mapping)
        dest_keys = mapping[:to].split(".")
        template = mapping[:from]
        Liquid::Template.register_filter(Liquid::CustomFilters)
        liquid_template = Liquid::Template.parse(template)
        rendered_text = liquid_template.render(record)
        extract_destination_mapping(dest_keys, rendered_text)
      end

      def custom_mapping(mapping)
        connector_name = @sync.destination.connector_name
        handler = ReverseEtl::Transformers::DestinationHandlers::Registry.handler_for(connector_name)

        result = handler.transform_custom_mapping(mapping, record, {
          sync: @sync,
          preload_indexes: @preload_indexes
        })

        return unless result.present?

        dest_keys = mapping[:to].split(".")
        extract_destination_mapping(dest_keys, result)
      end

      def extract_destination_mapping(dest_keys, mapped_destination_value)
        current = destination_data

        dest_keys.each_with_index do |key, index|
          is_last_key = index == dest_keys.length - 1
          is_array_key = key.include?("[]")

          if is_last_key
            # Handle array notation in the path
            set_value(current, key, mapped_destination_value, is_array_key)
          elsif is_array_key
            array_key = key.gsub("[]", "")
            current[array_key] ||= []
            # Use the last element of the array or create a new one if empty
            current = current[array_key].last || current[array_key].push({}).last
          else
            current[key] ||= {}
            current = current[key]
          end
        end

        current
      end

      def set_value(current, key, value, is_array)
        if is_array
          array_key = key.gsub("[]", "")
          current[array_key] ||= []
          current[array_key] << value
        else
          current[key] = value
        end
      end

      def destination_schema_available?(sync)
        sync.respond_to?(:destination) && sync.respond_to?(:stream_name)
      end

      def fetch_destination_schema(sync)
        return destination_schema if destination_schema.present?
        return {} unless destination_schema_available?(sync)

        destination = sync.destination
        catalog = destination&.catalog
        return {} unless catalog.present?

        catalog.json_schema(sync.stream_name) || {}
      rescue StandardError => e
        Rails.logger.debug({
          error_message: e.message,
          context: "UserMapping.fetch_destination_schema",
          sync_id: sync.respond_to?(:id) ? sync.id : nil
        }.to_s)
        {}
      end

      def extract_schema_properties(schema)
        schema_hash = convert_to_hash(schema)
        properties = schema_hash["properties"] || schema_hash[:properties] || {}
        properties.respond_to?(:with_indifferent_access) ? properties.with_indifferent_access : properties
      rescue StandardError
        {}
      end

      def convert_to_hash(schema)
        return {} if schema.blank?
        return schema if schema.is_a?(Hash)
        schema.respond_to?(:to_h) ? schema.to_h : {}
      end

      def apply_destination_schema!(data, schema_properties)
        return data unless data.is_a?(Hash)
        return data if schema_properties.blank?

        data.keys.each do |field|
          schema = schema_properties[field]
          next if schema.blank?

          data[field] = coerce_value(data[field], schema)
        end
        data
      end

      def coerce_value(value, schema)
        return value if value.nil? || schema.blank?

        schema_hash = schema.respond_to?(:with_indifferent_access) ? schema.with_indifferent_access : schema
        types = Array(schema_hash["type"]).map(&:to_s)
        format = schema_hash["format"]
        return value if types.empty?

        return coerce_array(value, schema_hash) if types.include?("array")
        return coerce_number(value) if (types & %w[number integer]).any?
        return coerce_boolean(value) if types.include?("boolean")
        return coerce_date(value, format) if %w[date date-time].include?(format)

        value
      end

      def coerce_array(value, schema)
        return value unless value.is_a?(Array)

        item_schema = schema["items"] || {}
        return value if item_schema.blank?

        value.map { |item| coerce_value(item, item_schema) }
      end

      INTEGER_PATTERN = /\A[-+]?\d+\z/.freeze
      DECIMAL_PATTERN = /\A[-+]?\d+(\.\d+)?\z/.freeze

      def coerce_number(value)
        return value if value.nil? || value.is_a?(Numeric)
        return value unless value.is_a?(String)

        normalized = value.strip
        return value if normalized.empty?
        return value unless normalized.match?(DECIMAL_PATTERN)

        return normalized.to_i if normalized.match?(INTEGER_PATTERN)

        normalized.to_f
      end

      def coerce_boolean(value)
        return value if value.nil? || value == true || value == false
        return value unless value.respond_to?(:to_s)

        normalized = value.to_s.strip.downcase
        return true if %w[true 1 yes y].include?(normalized)
        return false if %w[false 0 no n].include?(normalized)

        value
      end

      def coerce_date(value, format)
        return value if value.nil?
        return value if value.is_a?(Date) || value.is_a?(Time) || value.is_a?(DateTime)
        return value unless value.is_a?(String)

        normalized = value.strip
        return value if normalized.empty?

        begin
          # Parse the datetime string and convert to ISO 8601 format
          parsed_time = parse_datetime(normalized)
          return value unless parsed_time

          # For date format, return just the date part
          if format == "date"
            parsed_time.strftime("%Y-%m-%d")
          else
            # For date-time format, return ISO 8601 with timezone
            parsed_time.iso8601
          end
        rescue StandardError => e
          Rails.logger.debug({
            error_message: "Failed to coerce date value: #{e.message}",
            value: value,
            format: format
          }.to_s)
          value
        end
      end

      def parse_datetime(value)
        # Try parsing as ISO 8601 first
        return Time.parse(value) if value.match?(/^\d{4}-\d{2}-\d{2}/)

        # Try other common formats
        return DateTime.strptime(value, "%Y-%m-%d %H:%M:%S%z") if value.match?(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
        return DateTime.strptime(value, "%m/%d/%Y") if value.match?(%r{^\d{1,2}/\d{1,2}/\d{4}$})

        # Fallback to Time.parse for other formats
        Time.parse(value)
      rescue StandardError
        nil
      end
    end
  end
end
