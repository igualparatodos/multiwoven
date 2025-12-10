# frozen_string_literal: true

require_relative "schema_helper"
module Multiwoven
  module Integrations
    module Destination
      module Airtable
        include Multiwoven::Integrations::Core
        class Client < DestinationConnector
          prepend Multiwoven::Integrations::Core::RateLimiter
          MAX_CHUNK_SIZE = 10

          # Maintain lookup index across multiple write calls for the same sync run
          attr_accessor :sync_run_lookup_cache

          def initialize
            super
            @sync_run_lookup_cache = {}
            @cache_mutex = Mutex.new
          end

          def check_connection(connection_config)
            connection_config = connection_config.with_indifferent_access
            bases = Multiwoven::Integrations::Core::HttpClient.request(
              AIRTABLE_BASES_ENDPOINT,
              HTTP_GET,
              headers: auth_headers(connection_config[:api_key])
            )
            if success?(bases)
              base_id_exists?(bases, connection_config[:base_id])
              success_status
            else
              failure_status(nil)
            end
          rescue StandardError => e
            failure_status(e)
          end

          def discover(connection_config)
            connection_config = connection_config.with_indifferent_access
            base_id = connection_config[:base_id]
            api_key = connection_config[:api_key]

            bases = Multiwoven::Integrations::Core::HttpClient.request(
              AIRTABLE_BASES_ENDPOINT,
              HTTP_GET,
              headers: auth_headers(api_key)
            )

            base = extract_bases(bases).find { |b| b["id"] == base_id }
            base_name = base["name"]

            schema = Multiwoven::Integrations::Core::HttpClient.request(
              AIRTABLE_GET_BASE_SCHEMA_ENDPOINT.gsub("{baseId}", base_id),
              HTTP_GET,
              headers: auth_headers(api_key)
            )

            catalog = build_catalog_from_schema(extract_body(schema), base_id, base_name)
            catalog.to_multiwoven_message
          rescue StandardError => e
            handle_exception(e, {
                               context: "AIRTABLE:DISCOVER:EXCEPTION",
                               type: "error"
                             })
          end

          def write(sync_config, records, _action = "create")
            connection_config = sync_config.destination.connection_specification.with_indifferent_access
            api_key = connection_config[:api_key]
            base_id = connection_config[:base_id]
            url = sync_config.stream.url
            table_id = sync_config.stream.respond_to?(:x_airtable) ? sync_config.stream.x_airtable["table_id"] : nil

            destination_sync_mode = sync_config.destination_sync_mode

            log_message_array = []
            write_success = 0
            write_failure = 0

            case destination_sync_mode
            when "destination_upsert"
              write_success, write_failure, log_message_array = process_upsert(
                records, api_key, base_id, table_id, url, sync_config
              )
            when "destination_update"
              write_success, write_failure, log_message_array = process_update(
                records, api_key, base_id, table_id, url, sync_config
              )
            else # "destination_insert"
              write_success, write_failure, log_message_array = process_insert(
                records, url, api_key, sync_config
              )
            end

            tracking_message(write_success, write_failure, log_message_array)
          rescue StandardError => e
            handle_exception(e, {
                               context: "AIRTABLE:RECORD:WRITE:EXCEPTION",
                               type: "error",
                               sync_id: sync_config.sync_id,
                               sync_run_id: sync_config.sync_run_id
                             })
          end

          private

          def create_log_for_record(record, level, request_args, response)
            Multiwoven::Integrations::Protocol::LogMessage.new(
              name: self.class.name,
              level: level,
              message: {
                request: request_args.to_s,
                response: response.to_s,
                level: level,
                record: record
              }.to_json
            )
          end

          def create_payload(records)
            {
              "records" => records.map do |record|
                {
                  "fields" => filter_system_fields(record)
                }
              end
            }
          end

          def base_id_exists?(bases, base_id)
            return if extract_bases(bases).any? { |base| base["id"] == base_id }

            raise ArgumentError, "base_id not found"
          end

          def extract_bases(response)
            response_body = extract_body(response)
            response_body["bases"] if response_body
          end

          def extract_body(response)
            response_body = response.body
            JSON.parse(response_body) if response_body
          end

          def load_catalog
            read_json(CATALOG_SPEC_PATH)
          end

          def create_stream(table, base_id, base_name)
            {
              name: "#{base_name}/#{SchemaHelper.clean_name(table["name"])}",
              action: "create",
              method: HTTP_POST,
              url: "#{AIRTABLE_URL_BASE}#{base_id}/#{table["id"]}",
              json_schema: SchemaHelper.get_json_schema(table),
              supported_sync_modes: %w[incremental full_refresh],
              batch_support: true,
              batch_size: 10,
              # Airtable table id for use by clients
              x_airtable: { table_id: table["id"] }

            }.with_indifferent_access
          end

          def build_catalog_from_schema(schema, base_id, base_name)
            catalog = build_catalog(load_catalog)
            schema["tables"].each do |table|
              catalog.streams << build_stream(create_stream(table, base_id, base_name))
            end
            catalog
          end

          def process_insert(records, url, api_key, sync_config)
            log_message_array = []
            write_success = 0
            write_failure = 0

            records.each_slice(MAX_CHUNK_SIZE) do |chunk|
              payload = create_payload(chunk)
              args = [HTTP_POST, url, payload]

              response = Multiwoven::Integrations::Core::HttpClient.request(
                url,
                HTTP_POST,
                payload: payload,
                headers: auth_headers(api_key),
                options: { params: { typecast: true } }
              )

              if success?(response)
                write_success += chunk.size
                chunk.each { |r| log_message_array << create_log_for_record(r, "info", args, response) }
              else
                write_failure += chunk.size
                raise StandardError, "Airtable write failed response=#{response.body}"
              end
            rescue StandardError => e
              handle_exception(e, { context: "AIRTABLE:INSERT:EXCEPTION", type: "error",
                                    sync_id: sync_config.sync_id, sync_run_id: sync_config.sync_run_id })
              write_failure += chunk.size
              chunk.each { |r| log_message_array << create_log_for_record(r, "error", args, e.message) }
            end

            [write_success, write_failure, log_message_array]
          end

          def process_upsert(records, api_key, base_id, table_id, url, sync_config)
            unique_config = extract_unique_identifier(sync_config)

            # Fallback to insert if no unique field configured
            unless unique_config
              return process_insert(records, url, api_key, sync_config)
            end

            source_field = unique_config["source_field"]
            destination_field = unique_config["destination_field"]

            log_message_array = []
            write_success = 0
            write_failure = 0

            # Skip lookup table if using recordId as unique identifier
            # In this case, records already contain the Airtable record ID
            use_record_id = destination_field.to_s.downcase == "recordid"

            # Initialize or retrieve lookup cache for this sync run (thread-safe)
            # Skip caching if using recordId since we don't need a lookup table
            cache_key = "#{sync_config.sync_run_id}_#{table_id}_#{destination_field}"

            lookup_index = if use_record_id
                             nil
                           else
                             @cache_mutex.synchronize do
                               if @sync_run_lookup_cache[cache_key]
                                 # Return a copy to avoid concurrent modification
                                 @sync_run_lookup_cache[cache_key].dup
                               else
                                 # Build FULL lookup index by scanning entire Airtable table once
                                 resolver = ReverseEtl::Transformers::DestinationHandlers::Airtable::LinkResolver.new(
                                   api_key: api_key,
                                   base_id: base_id
                                 )
                                 new_index = resolver.build_full_index(
                                   linked_table_id: table_id,
                                   match_field: destination_field
                                 )
                                 @sync_run_lookup_cache[cache_key] = new_index
                                 new_index.dup
                               end
                             end
                           end

            records.each_slice(MAX_CHUNK_SIZE) do |chunk|
              creates = []
              updates = []

              # Separate records into creates vs updates
              chunk.each do |record|
                # Handle both string and symbol keys for field access
                unique_value = record[destination_field] || record[destination_field.to_sym] || record[destination_field.to_s]

                # If using recordId, the unique_value IS the Airtable record ID
                airtable_id = if use_record_id
                                unique_value
                              else
                                lookup_index[unique_value]&.first
                              end

                if airtable_id.present?
                  updates << { id: airtable_id, fields: filter_system_fields(record) }
                else
                  creates << filter_system_fields(record)
                end
              end

              # Batch create new records
              if creates.any?
                result = batch_create(creates, url, api_key, sync_config)
                write_success += result[:success]
                write_failure += result[:failure]
                log_message_array.concat(result[:logs])

                # Update lookup_index with newly created records to prevent duplicates in subsequent batches
                # Skip this if using recordId since we don't maintain a lookup table
                if !use_record_id && result[:created_records]
                  result[:created_records].each do |created_record|
                    unique_value = created_record["fields"][destination_field]
                    record_id = created_record["id"]
                    lookup_index[unique_value] ||= []
                    lookup_index[unique_value] << record_id unless lookup_index[unique_value].include?(record_id)
                  end
                end
              end

              # Batch update existing records
              if updates.any?
                result = batch_update(updates, url, api_key, sync_config)
                write_success += result[:success]
                write_failure += result[:failure]
                log_message_array.concat(result[:logs])
              end
            rescue StandardError => e
              handle_exception(e, { context: "AIRTABLE:UPSERT:EXCEPTION", type: "error",
                                    sync_id: sync_config.sync_id, sync_run_id: sync_config.sync_run_id })
              write_failure += chunk.size
              chunk.each { |r| log_message_array << create_log_for_record(r, "error", ["UPSERT", url, r], e.message) }
            end

            # Save updated lookup_index back to cache for next batch (thread-safe)
            # Skip this if using recordId since we don't maintain a lookup table
            unless use_record_id
              @cache_mutex.synchronize do
                @sync_run_lookup_cache[cache_key] = lookup_index
              end
            end

            [write_success, write_failure, log_message_array]
          end

          def process_update(records, api_key, base_id, table_id, url, sync_config)
            unique_config = extract_unique_identifier(sync_config)

            log_message_array = []
            write_success = 0
            write_failure = 0

            unless unique_config
              write_failure += records.size
              records.each { |r| log_message_array << create_log_for_record(r, "error", ["UPDATE", url, r],
                                                                             "unique_identifier not configured") }
              return [write_success, write_failure, log_message_array]
            end

            source_field = unique_config["source_field"]
            destination_field = unique_config["destination_field"]

            # Skip lookup table if using recordId as unique identifier
            # In this case, records already contain the Airtable record ID
            use_record_id = destination_field.to_s.downcase == "recordid"
            lookup_index = use_record_id ? nil : build_lookup_index(records, destination_field, destination_field, api_key, base_id, table_id)

            records.each_slice(MAX_CHUNK_SIZE) do |chunk|
              updates = []

              chunk.each do |record|
                # Handle both string and symbol keys for field access
                unique_value = record[destination_field] || record[destination_field.to_sym] || record[destination_field.to_s]

                # If using recordId, the unique_value IS the Airtable record ID
                airtable_id = if use_record_id
                                unique_value
                              else
                                lookup_index[unique_value]&.first
                              end

                if airtable_id.present?
                  updates << { id: airtable_id, fields: filter_system_fields(record) }
                else
                  # Record not found - log as failure
                  write_failure += 1
                  log_message_array << create_log_for_record(record, "error", ["UPDATE", url, record],
                                                              "Record not found: #{destination_field}=#{unique_value}")
                end
              end

              if updates.any?
                result = batch_update(updates, url, api_key, sync_config)
                write_success += result[:success]
                write_failure += result[:failure]
                log_message_array.concat(result[:logs])
              end
            rescue StandardError => e
              handle_exception(e, { context: "AIRTABLE:UPDATE:EXCEPTION", type: "error",
                                    sync_id: sync_config.sync_id, sync_run_id: sync_config.sync_run_id })
              write_failure += chunk.size
              chunk.each { |r| log_message_array << create_log_for_record(r, "error", ["UPDATE", url, r], e.message) }
            end

            [write_success, write_failure, log_message_array]
          end

          def build_lookup_index(records, record_field, airtable_field, api_key, base_id, table_id)
            # Extract unique values from transformed records (records already have destination field names)
            unique_values = records.map { |r| r[record_field] }.compact.uniq
            return {} if unique_values.empty?

            # Reuse existing LinkResolver
            resolver = ReverseEtl::Transformers::DestinationHandlers::Airtable::LinkResolver.new(
              api_key: api_key,
              base_id: base_id
            )

            # Lookup in Airtable using the Airtable field name
            result = resolver.find_record_ids_by_values(
              linked_table_id: table_id,
              match_field: airtable_field,
              values: unique_values
            )

            result
          rescue StandardError => e
            handle_exception(e, { context: "AIRTABLE:LOOKUP_INDEX:EXCEPTION", type: "error" })
            {}
          end

          def batch_create(records, url, api_key, sync_config)
            payload = create_payload(records)

            response = Multiwoven::Integrations::Core::HttpClient.request(
              url, HTTP_POST,
              payload: payload,
              headers: auth_headers(api_key),
              options: { params: { typecast: true } }
            )

            if success?(response)
              # Parse response to extract created record IDs for lookup_index update
              begin
                response_body = JSON.parse(response.body)
                created_records = response_body["records"] || []
              rescue StandardError => e
                created_records = []
              end

              { success: records.size, failure: 0,
                created_records: created_records,
                logs: records.map { |r| create_log_for_record(r, "info", [HTTP_POST, url, payload], response) } }
            else
              { success: 0, failure: records.size,
                logs: records.map { |r| create_log_for_record(r, "error", [HTTP_POST, url, payload], "HTTP #{response.code}") } }
            end
          rescue StandardError => e
            Rails.logger.error("[AIRTABLE:BATCH_CREATE] Exception: #{e.class} - #{e.message}")
            { success: 0, failure: records.size,
              logs: records.map { |r| create_log_for_record(r, "error", [HTTP_POST, url, payload], e.message) } }
          end

          def batch_update(updates, url, api_key, sync_config)
            payload = { records: updates }
            response = Multiwoven::Integrations::Core::HttpClient.request(
              url, HTTP_PATCH,
              payload: payload,
              headers: auth_headers(api_key),
              options: { params: { typecast: true } }
            )

            if success?(response)
              { success: updates.size, failure: 0,
                logs: updates.map { |u| create_log_for_record(u[:fields], "info", [HTTP_PATCH, url, payload], response) } }
            else
              { success: 0, failure: updates.size,
                logs: updates.map { |u| create_log_for_record(u[:fields], "error", [HTTP_PATCH, url, payload], response.body) } }
            end
          rescue StandardError => e
            { success: 0, failure: updates.size,
              logs: updates.map { |u| create_log_for_record(u[:fields], "error", [HTTP_PATCH, url, payload], e.message) } }
          end

          def extract_unique_identifier(sync_config)
            # Access via singleton method added in Sync.build_stream_with_unique_identifier
            # Returns hash with source_field (for record lookup) and destination_field (for Airtable lookup)
            if sync_config.stream.respond_to?(:unique_identifier_config)
              sync_config.stream.unique_identifier_config
            else
              nil
            end
          end

          def filter_system_fields(record)
            # Remove Airtable system fields (read-only) from the record
            # recordId should not be sent as a field in create/update requests
            record.reject { |key, _| key.to_s.downcase == "recordid" }
          end

        end
      end
    end
  end
end
