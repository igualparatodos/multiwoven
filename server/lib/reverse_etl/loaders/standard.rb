# frozen_string_literal: true

require_relative "../transformers/destination_handlers/registry"

module ReverseEtl
  module Loaders
    class Standard < Base
      THREAD_COUNT = (ENV["SYNC_LOADER_THREAD_POOL_SIZE"] || "5").to_i
      def write(sync_run_id, activity)
        sync_run = SyncRun.find(sync_run_id)

        return log_error(sync_run) unless sync_run.may_progress?

        # change state queued to in_progress
        sync_run.progress!

        sync = sync_run.sync
        sync_config = sync.to_protocol
        sync_config.sync_run_id = sync_run.id.to_s

        if sync_config.stream.batch_support && !sync_run.test?
          # Build preload indexes once per run and reuse across all batches
          preload_indexes = build_preload_indexes(sync)
          process_batch_records(sync_run, sync, sync_config, activity, preload_indexes)
        else
          process_individual_records(sync_run, sync, sync_config, activity)
        end
      end

      private

      def process_individual_records(sync_run, sync, sync_config, activity)
        client = sync.destination.connector_client.new

        sync_run.sync_records.pending.find_in_batches do |sync_records|
          # concurrent request rate limit
          concurrency = sync_config.stream.request_rate_concurrency || THREAD_COUNT

          Parallel.each(sync_records, in_threads: concurrency) do |sync_record|
            transformer = Transformers::UserMapping.new
            transformer.destination_schema = sync_config.stream&.json_schema
            transformer.preload_indexes = preload_indexes
            record = transformer.transform(sync, sync_record)
            Rails.logger.info "sync_id = #{sync.id} sync_run_id = #{sync_run.id} sync_record = #{record}"
            report = handle_response(client.write(sync_config, [record], sync_record.action), sync_run)
            update_sync_record_logs_and_status(report, sync_record)
          rescue Activities::LoaderActivity::FullRefreshFailed
            raise
          rescue StandardError => e
            # Utils::ExceptionReporter.report(e, {
            #                                   sync_run_id: sync_run.id,
            #                                   sync_id: sync.id
            #                                 })
            Rails.logger.error({
              error_message: e.message,
              sync_run_id: sync_run.id,
              sync_id: sync_run.sync_id,
              stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
            }.to_s)
          end

          heartbeat(activity, sync_run)
        end
      end

      def build_preload_indexes(sync)
        connector_name = sync.destination.connector_name
        handler = ReverseEtl::Transformers::DestinationHandlers::Registry.handler_for(connector_name)
        handler.build_custom_mapping_indexes(sync, sync.configuration)
      rescue StandardError => e
        Rails.logger.error({
          error_message: e.message,
          context: "build_preload_indexes",
          stack_trace: Rails.backtrace_cleaner.clean(e.backtrace)
        }.to_s)
        {}
      end

      def process_batch_records(sync_run, sync, sync_config, activity, preload_indexes)
        client = sync.destination.connector_client.new
        batch_size = sync_config.stream.batch_size
        Rails.logger.info("[LOADER] process_batch_records started: sync_run_id=#{sync_run.id}, sync_id=#{sync.id}, destination_sync_mode=#{sync_config.destination_sync_mode}, batch_size=#{batch_size}, pending_records=#{sync_run.sync_records.pending.count}")

        # track sync record status
        successfull_sync_records = []
        failed_sync_records = []

        Parallel.each(sync_run.sync_records.pending.find_in_batches(batch_size:),
                      in_threads: THREAD_COUNT) do |sync_records|
          transformer = Transformers::UserMapping.new
          transformer.preload_indexes = preload_indexes
          transformer.destination_schema = sync_config.stream&.json_schema

          transformed_records = sync_records.map { |sync_record| transformer.transform(sync, sync_record) }
          report = handle_response(client.write(sync_config, transformed_records), sync_run)

          # Update sync_records with per-record logs and status
          update_batch_sync_records_with_logs(sync_records, report)

          if report.tracking.success.zero?
            failed_sync_records.concat(sync_records.map(&:id).compact)
          else
            successfull_sync_records.concat(sync_records.map(&:id).compact)
          end
        rescue Activities::LoaderActivity::FullRefreshFailed
          raise
        rescue StandardError => e
          Rails.logger.error("[LOADER] Error in process_batch_records: #{e.message}, sync_run_id: #{sync_run.id}, trace: #{e.backtrace.first(5)}")
          # Utils::ExceptionReporter.report(e, {
          #                                   sync_run_id: sync_run.id
          #                                 })
        end
        update_sync_records_status(sync_run, successfull_sync_records, failed_sync_records)
        heartbeat(activity, sync_run)
      end

      def handle_response(report, sync_run)
        is_multiwoven_tracking_message = report.is_a?(Multiwoven::Integrations::Protocol::MultiwovenMessage) &&
                                         report.type == "tracking" &&
                                         report.tracking.is_a?(Multiwoven::Integrations::Protocol::TrackingMessage)
        raise_non_retryable_error(report, sync_run) unless is_multiwoven_tracking_message
        report
      end

      def raise_non_retryable_error(report, sync_run)
        sync_run.failed!
        Rails.logger.error({
          error_message: "Full refresh failed type:#{report.control.type} status: #{report.control.status}",
          sync_run_id: sync_run.id,
          stack_trace: nil
        }.to_s)
        raise Activities::LoaderActivity::FullRefreshFailed, "Full refresh failed (non-retryable)"
      end

      def update_sync_record_logs_and_status(report, sync_record)
        status = report.tracking.success.zero? ? "failed" : "success"
        sync_record.update(logs: get_sync_records_logs(report), status:)
      end

      def update_batch_sync_records_with_logs(sync_records, report)
        return unless report.tracking.respond_to?(:logs) && report.tracking.logs.present?

        # Map each log to its corresponding sync_record (they're in the same order)
        logs = report.tracking.logs
        sync_records.each_with_index do |sync_record, index|
          # Get the log for this record (or use the first log if there aren't enough)
          log = logs[index] || logs.first
          next unless log&.message.present?

          begin
            parsed_log = JSON.parse(log.message)
            sync_record.update(logs: parsed_log)
          rescue JSON::ParserError => e
            Rails.logger.error("Failed to parse log message for sync_record #{sync_record.id}: #{e.message}")
          end
        end
      end

      def get_sync_records_logs(report)
        return unless report.tracking.respond_to?(:logs) && report.tracking.logs&.first&.message.present?

        JSON.parse(report.tracking.logs.first.message)
      end

      def update_sync_records_status(sync_run, successfull_sync_records, failed_sync_records)
        sync_run.sync_records.where(id: successfull_sync_records).update_all(status: "success") # rubocop:disable Rails/SkipsModelValidations
        sync_run.sync_records.where(id: failed_sync_records).update_all(status: "failed") # rubocop:disable Rails/SkipsModelValidations
      end

      def heartbeat(activity, sync_run)
        response = activity.heartbeat
        return unless response.cancel_requested

        sync_run.failed!
        Rails.logger.error({
          error_message: "Cancel activity request received",
          sync_run_id: sync_run.id,
          sync_id: sync_run.sync_id,
          stack_trace: nil
        }.to_s)
        raise StandardError, "Cancel activity request received"
      end

      def log_error(sync_run)
        Rails.logger.error({
          error_message: "SyncRun cannot progress from its current state: #{sync_run.status}",
          sync_run_id: sync_run.id,
          stack_trace: nil
        }.to_s)
      end

    end
  end
end
