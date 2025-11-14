# frozen_string_literal: true
# OVERRIDDEN: Modified to disable HostAuthorization for igual deployment
# This allows ALB health checks with pod IPs and any host headers to succeed
# Original behavior: Adds .squared.ai, .staging.squared.ai, localhost, and ENV["ALLOWED_HOST"]

unless Rails.env.test?
  # Disable HostAuthorization by clearing the hosts array and deleting the middleware
  Rails.application.config.hosts.clear
  Rails.application.config.middleware.delete ActionDispatch::HostAuthorization
end
