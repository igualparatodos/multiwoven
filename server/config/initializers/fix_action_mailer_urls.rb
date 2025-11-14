# frozen_string_literal: true
# Fix ActionMailer default_url_options to include protocol for absolute URLs
# Must run AFTER all initialization to override application.rb setting

Rails.application.config.after_initialize do
  # Set protocol + host for absolute URLs in emails
  Rails.application.config.action_mailer.default_url_options = {
    protocol: "https",
    host: ENV.fetch("SMTP_HOST", "multiwoven.igual.cloud")
  }

  Rails.logger.info "✅ ActionMailer URLs configured: https://#{ENV.fetch('SMTP_HOST', 'multiwoven.igual.cloud')}"
end
