# frozen_string_literal: true

require_relative "base"

module ReverseEtl
  module Transformers
    module DestinationHandlers
      class Registry
        # Returns the handler class for a given connector name
        # Uses naming convention: ReverseEtl::Transformers::DestinationHandlers::{ConnectorName}::Handler
        # Returns Base (no-op) if handler doesn't exist
        #
        # @param connector_name [String] The connector name (e.g., "Airtable")
        # @return [Class] The handler class for the connector
        def self.handler_for(connector_name)
          handler_class_name = "ReverseEtl::Transformers::DestinationHandlers::#{connector_name.camelize}::Handler"
          handler_class_name.constantize
        rescue NameError
          Base # Return base (no-op) if handler doesn't exist
        end
      end
    end
  end
end
