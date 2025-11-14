# frozen_string_literal: true
# Custom initializer: Restrict signups to specific email domains
# Set ALLOWED_EMAIL_DOMAINS env var (comma-separated) to restrict signups
# Example: ALLOWED_EMAIL_DOMAINS=igual.com,example.com

Rails.application.config.to_prepare do
  User.class_eval do
    # Use both validation and before_create to ensure domain check
    validate :email_domain_allowed
    before_create :check_email_domain_before_create

    private

    def email_domain_allowed
      return unless email.present?

      allowed_domains = ENV["ALLOWED_EMAIL_DOMAINS"]
      return if allowed_domains.blank?

      domains = allowed_domains.split(",").map(&:strip)
      email_domain = email.split("@").last&.downcase

      unless domains.any? { |domain| email_domain == domain.downcase }
        errors.add(:email, "domain not allowed. Only #{domains.join(', ')} emails are permitted")
      end
    end

    def check_email_domain_before_create
      return true unless email.present?

      allowed_domains = ENV["ALLOWED_EMAIL_DOMAINS"]
      return true if allowed_domains.blank?

      domains = allowed_domains.split(",").map(&:strip)
      email_domain = email.split("@").last&.downcase

      unless domains.any? { |domain| email_domain == domain.downcase }
        Rails.logger.warn "🚫 Blocked signup attempt: #{email} (domain not in allowed list: #{domains.join(', ')})"
        errors.add(:email, "domain not allowed. Only #{domains.join(', ')} emails are permitted")
        throw :abort
      end
    end
  end
end
