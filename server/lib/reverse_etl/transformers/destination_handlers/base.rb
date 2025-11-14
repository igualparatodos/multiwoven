# frozen_string_literal: true

module ReverseEtl
  module Transformers
    module DestinationHandlers
      class Base
        # Override this method in connectors that support custom mappings
        # @param mapping [Hash] The mapping configuration
        # @param record [Hash] The source record being transformed
        # @param context [Hash] Additional context (sync, preload_indexes, etc.)
        # @return [Object, nil] Transformed value or nil if not supported
        def self.transform_custom_mapping(mapping, record, context = {})
          nil # Return nil if not supported - transformer will skip
        end

        # Override this method to build preload indexes for batch operations
        # Only implement if your connector needs pre-loading for performance
        # @param sync [Sync] The sync object
        # @param mappings [Array] Array of mapping configurations
        # @return [Hash] Hash of preload indexes, empty hash if not needed
        def self.build_custom_mapping_indexes(sync, mappings)
          {} # Return empty hash if not needed
        end
      end
    end
  end
end
