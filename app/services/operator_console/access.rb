# frozen_string_literal: true

module OperatorConsole
  class Access
    class << self
      def allowed?(user)
        return false unless user
        return false unless configured?

        allowed_user_ids.include?(user.id.to_s) || allowed_emails.include?(normalized_email(user.email))
      end

      def configured?
        allowed_user_ids.any? || allowed_emails.any?
      end

      def allowed_user_ids
        configured_values(:user_ids, env_key: "PAID_OPERATOR_USER_IDS")
      end

      def allowed_emails
        configured_values(:emails, env_key: "PAID_OPERATOR_EMAILS").map do |email|
          normalized_email(email)
        end
      end

      def reset_memoized!
        nil
      end

      private

      def configured_values(credential_key, env_key:)
        return split_values(ENV.fetch(env_key)) if ENV.key?(env_key)

        credential_values = credentials_value(credential_key)
        Array(credential_values).flat_map { |value| split_values(value) }.uniq
      end

      def credentials_value(credential_key)
        Rails.application.credentials.dig(:operator_console, credential_key)
      rescue ActiveSupport::EncryptedFile::MissingKeyError,
        ActiveSupport::MessageEncryptor::InvalidMessage
        nil
      end

      def split_values(value)
        Array(value).flat_map { |entry| entry.to_s.split(/[,\s]+/) }
          .map(&:strip)
          .reject(&:blank?)
          .uniq
      end

      def normalized_email(email)
        email.to_s.strip.downcase
      end
    end
  end
end
