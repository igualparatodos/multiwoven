# frozen_string_literal: true

module ReverseEtl
  module Transformers
    module DestinationHandlers
      module Airtable
        class LinkResolver
          include ::Multiwoven::Integrations::Core::Constants

          def initialize(api_key:, base_id:)
            @api_key = api_key
            @base_id = base_id
          end

          # Returns a Hash mapping each input value to an Array of Airtable record IDs
          # Options:
          # - linked_table_id: Airtable table ID (e.g., "tblXXXX") to search within
          # - match_field: Airtable field name to match against (e.g., "Name")
          # - values: Array<String> of values to resolve
          def find_record_ids_by_values(linked_table_id:, match_field:, values:)
            return {} if values.blank?

            values.uniq.each_with_object({}) do |value, result|
              result[value] = find_record_ids_by_value(
                linked_table_id:,
                match_field:,
                value:
              )
            end
          end

          # Returns an Array<String> of record IDs for a single value match
          def find_record_ids_by_value(linked_table_id:, match_field:, value:)
            ids = []
            params = {
              "filterByFormula" => build_equals_formula(match_field, value)
            }

            url = "#{AIRTABLE_URL_BASE}#{@base_id}/#{linked_table_id}"

            loop do
              response = ::Multiwoven::Integrations::Core::HttpClient.request(
                url,
                HTTP_GET,
                headers: auth_headers,
                options: { params: }
              )

              body = safe_parse_body(response)
              break unless body.is_a?(Hash)

              (body["records"] || []).each do |rec|
                ids << rec["id"] if rec["id"].present?
              end

              offset = body["offset"]
              break if offset.blank?

              params = params.merge("offset" => offset)
            end

            ids
          rescue StandardError => e
            Rails.logger.error({
              error_message: e.message,
              context: "Airtable::LinkResolver.find_record_ids_by_value",
              stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
            }.to_s)
            []
          end

          # Build a full index of match_field value -> [record_ids] by scanning the linked table once.
          # This is far more efficient than per-row lookups for batches with many distinct values.
          def build_full_index(linked_table_id:, match_field:)
            value_to_ids = Hash.new { |h, k| h[k] = [] }
            params = { "pageSize" => 100, "fields[]" => [match_field] }
            url = "#{AIRTABLE_URL_BASE}#{@base_id}/#{linked_table_id}"
            loop do
              response = ::Multiwoven::Integrations::Core::HttpClient.request(
                url,
                HTTP_GET,
                headers: auth_headers,
                options: { params: }
              )
              body = safe_parse_body(response)
              break unless body.is_a?(Hash)

              (body["records"] || []).each do |rec|
                id = rec["id"]
                fields = rec["fields"] || {}
                val = fields[match_field]
                next if id.blank? || val.nil?
                # match_field can be singular or array; normalize to array
                Array(val).each { |v| value_to_ids[v] << id }
              end

              offset = body["offset"]
              break if offset.blank?
              params = params.merge("offset" => offset)
            end

            value_to_ids
          rescue StandardError => e
            Rails.logger.error({
              error_message: e.message,
              context: "AirtableLinkResolver.build_full_index",
              stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
            }.to_s)
            {}
          end

          private

          def auth_headers
            {
              "Authorization" => "Bearer #{@api_key}",
              "Content-Type" => "application/json"
            }
          end

          def safe_parse_body(response)
            return {} unless response && response.respond_to?(:body)
            JSON.parse(response.body)
          rescue JSON::ParserError
            {}
          end

          # Escapes single quotes and builds a formula like: {Name}='Alice'
          def build_equals_formula(field_name, value)
            escaped = value.to_s.gsub("'", "''")
            "{#{field_name}}='#{escaped}'"
          end
        end
      end
    end
  end
end
