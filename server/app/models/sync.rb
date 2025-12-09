# frozen_string_literal: true

# == Schema Information
#
# Table name: syncs
#
#  id                :bigint           not null, primary key
#  workspace_id      :integer
#  source_id         :integer
#  model_id          :integer
#  destination_id    :integer
#  configuration     :jsonb
#  source_catalog_id :integer
#  schedule_type     :string
#  sync_interval     :integer
#  sync_interval_unit:string
#  cron_expression   :string
#  status            :integer
#  cursor_field      :string
#  current_cursor_field :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class Sync < ApplicationRecord # rubocop:disable Metrics/ClassLength
  include AASM
  include Discard::Model

  validates :workspace_id, presence: true
  validates :source_id, presence: true
  validates :destination_id, presence: true
  validates :model_id, presence: true
  validates :configuration, presence: true
  validates :schedule_type, presence: true
  validates :sync_interval, presence: true, numericality: { greater_than: 0 }, if: :interval?
  validates :sync_interval_unit, presence: true, if: :interval?
  validates :cron_expression, presence: true, if: :cron_expression?
  validates :stream_name, presence: true
  validates :status, presence: true
  validate :stream_name_exists?
  validate :unique_identifier_required_for_upsert_or_update
  validate :unique_identifier_field_exists_in_schema

  enum :schedule_type, %i[manual interval cron_expression]
  enum :status, %i[disabled healthy pending failed aborted]
  enum :sync_mode, %i[full_refresh incremental]
  enum :sync_interval_unit, %i[minutes hours days weeks]
  enum :destination_sync_mode, %i[destination_insert destination_upsert destination_update]

  belongs_to :workspace
  belongs_to :source, class_name: "Connector"
  belongs_to :destination, class_name: "Connector"
  belongs_to :model
  has_many :sync_runs, dependent: :destroy
  has_many :sync_files, dependent: :destroy

  after_initialize :set_defaults, if: :new_record?
  before_validation :infer_and_update_unique_identifier_config
  after_save :schedule_sync, if: :schedule_sync?
  after_update :terminate_sync, if: :terminate_sync?
  after_discard :perform_post_discard_sync

  default_scope -> { kept.order(updated_at: :desc) }

  aasm column: :status, whiny_transitions: true do
    state :pending, initial: true
    state :healthy
    state :failed
    state :disabled

    event :complete do
      transitions from: %i[pending healthy], to: :healthy
    end

    event :fail do
      transitions from: %i[pending healthy], to: :failed
    end

    event :disable do
      transitions from: %i[pending healthy failed], to: :disabled
    end

    event :enable do
      transitions from: :disabled, to: :pending
    end
  end

  def to_protocol
    catalog = destination.catalog
    Multiwoven::Integrations::Protocol::SyncConfig.new(
      model: model.to_protocol,
      source: source.to_protocol,
      destination: destination.to_protocol,
      stream: build_stream_with_unique_identifier(
        catalog.stream_to_protocol(catalog.find_stream_by_name(stream_name))
      ),
      sync_mode: Multiwoven::Integrations::Protocol::SyncMode[sync_mode],
      destination_sync_mode: Multiwoven::Integrations::Protocol::DestinationSyncMode[
        destination_sync_mode || "destination_insert"
      ],
      cursor_field:,
      current_cursor_field:,
      sync_id: id.to_s,
      increment_strategy_config:
    )
  end

  def increment_strategy_config
    increment_type = source.configuration["increment_type"]
    return nil if source.configuration["increment_type"].nil?

    offset = source.configuration["page_start"].to_i
    limit = source.configuration["page_size"].to_i

    increment_strategy_config = Multiwoven::Integrations::Protocol::IncrementStrategyConfig.new(
      increment_strategy: increment_type.downcase
    )
    increment_strategy_config.offset = increment_type == "Page" ? offset.nonzero? || 1 : offset
    increment_strategy_config.limit = increment_type == "Page" ? limit.nonzero? || 10 : limit
    increment_strategy_config.offset_variable = source.configuration["offset_param"]
    increment_strategy_config.limit_variable = source.configuration["limit_param"]
    increment_strategy_config
  end

  def set_defaults
    self.status ||= self.class.aasm.initial_state.to_s
  end

  def schedule_cron_expression
    return cron_expression if cron_expression?

    case sync_interval_unit.downcase
    when "minutes"
      # Every X minutes: */X * * * *
      "*/#{sync_interval} * * * *"
    when "hours"
      # Every X hours: 0 */X * * *
      "0 */#{sync_interval} * * *"
    when "days"
      # Every X days: 0 0 */X * *
      "0 0 */#{sync_interval} * *"
    when "weeks"
      # Every X days: 0 0 */X*7 * *
      "0 0 */#{sync_interval * 7} * *"
    else
      raise ArgumentError, "Invalid sync_interval_unit: #{sync_interval_unit}"
    end
  end

  def schedule_sync?
    (new_record? || saved_change_to_sync_interval? || saved_change_to_sync_interval_unit ||
      saved_change_to_cron_expression? || (saved_change_to_status? && status == "pending")) && !manual?
  end

  def schedule_sync
    Temporal.start_workflow(
      Workflows::ScheduleSyncWorkflow,
      id
    )
  rescue StandardError => e
    Utils::ExceptionReporter.report(e, { sync_id: id })
    Rails.logger.error "Failed to schedule sync with Temporal. Error: #{e.message}"
  end

  def terminate_sync?
    saved_change_to_status? && status == "disabled"
  end

  def terminate_sync
    terminate_workflow_id = "terminate-#{workflow_id}"
    Temporal.start_workflow(Workflows::TerminateWorkflow, workflow_id, options: { workflow_id: terminate_workflow_id })
  rescue StandardError => e
    Utils::ExceptionReporter.report(e, { sync_id: id })
    Rails.logger.error "Failed to terminate sync with Temporal. Error: #{e.message}"
  end

  def perform_post_discard_sync
    sync_runs.discard_all
    terminate_sync
  rescue StandardError => e
    Utils::ExceptionReporter.report(e, { sync_id: id })
    Rails.logger.error "Failed to Run post delete sync. Error: #{e.message}"
  end

  def stream_name_exists?
    return if destination.blank?

    catalog = destination&.catalog
    if catalog.blank?
      errors.add(:catalog, "Catalog is missing")
    elsif catalog.find_stream_by_name(stream_name).blank?
      errors.add(:stream_name,
                 "Add a valid stream_name associated with destination connector")
    end
  end

  def build_stream_with_unique_identifier(stream_protocol)
    # Get the original stream from catalog to access x_airtable
    catalog = destination.catalog
    original_stream = catalog.find_stream_by_name(stream_name)

    # Preserve x_airtable attribute if it exists (needed for Airtable table_id)
    if original_stream.respond_to?(:x_airtable) || (original_stream.is_a?(Hash) && original_stream["x_airtable"])
      x_airtable_data = original_stream.respond_to?(:x_airtable) ? original_stream.x_airtable : original_stream["x_airtable"]
      stream_protocol.define_singleton_method(:x_airtable) do
        x_airtable_data
      end
    end

    if (destination_upsert? || destination_update?) && unique_identifier_config.present?
      # Infer source_field from configuration mappings if not explicitly set
      config = infer_source_field_from_mappings(unique_identifier_config)

      # Extend stream with unique_identifier_config via singleton method
      stream_protocol.define_singleton_method(:unique_identifier_config) do
        config
      end
    end
    stream_protocol
  end

  def infer_source_field_from_mappings(config)
    destination_field = config["destination_field"]
    source_field = config["source_field"]

    # If source_field is not set or equals destination_field, infer it from mappings
    if source_field.blank? || source_field == destination_field
      # Look for a mapping where 'to' equals the destination_field
      mapping = configuration.find { |m| m["to"] == destination_field }
      if mapping
        source_field = mapping["from"]
        Rails.logger.info("Inferred source_field '#{source_field}' from mapping '#{mapping['from']}' -> '#{mapping['to']}'")
      else
        # If no mapping found, assume source and destination fields have the same name
        source_field = destination_field
        Rails.logger.warn("No mapping found for destination_field '#{destination_field}', using same name for source_field")
      end
    end

    { "source_field" => source_field, "destination_field" => destination_field }
  end

  def infer_and_update_unique_identifier_config
    return unless (destination_upsert? || destination_update?) && unique_identifier_config.present?

    inferred_config = infer_source_field_from_mappings(unique_identifier_config)
    self.unique_identifier_config = inferred_config
  end

  def unique_identifier_required_for_upsert_or_update
    return unless destination_upsert? || destination_update?
    return if unique_identifier_config.present? &&
              unique_identifier_config["source_field"].present? &&
              unique_identifier_config["destination_field"].present?

    errors.add(:unique_identifier_config,
               "must specify source_field and destination_field for upsert/update")
  end

  def unique_identifier_field_exists_in_schema
    return unless unique_identifier_config&.dig("destination_field").present?

    catalog = destination&.catalog
    return unless catalog

    stream = catalog.find_stream_by_name(stream_name)
    return unless stream

    # Handle both hash and object access
    json_schema = stream.respond_to?(:json_schema) ? stream.json_schema : stream[:json_schema]
    return unless json_schema

    schema_properties = json_schema[:properties] || json_schema["properties"] || {}
    dest_field = unique_identifier_config["destination_field"]

    unless schema_properties.key?(dest_field) || schema_properties.key?(dest_field.to_sym)
      errors.add(:unique_identifier_config,
                 "destination_field '#{dest_field}' not found in Airtable schema")
    end
  end
end
