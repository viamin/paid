# frozen_string_literal: true

module Screenshots
  module SeedData
    # Minimal, isolated data for Paid's browser-verification pilot. The broader
    # screenshot seed remains responsible for screenshot-gallery coverage.
    # @spec LIVE-PREVIEW-012
    class PaidJourney
      ACCOUNT_SLUG = "paid-journey-account".freeze
      USER_EMAIL = "paid-journey@example.com".freeze
      USER_PASSWORD = "paid-journey-password-123".freeze
      PROJECT_NAME = "Paid Journey Project".freeze
      PROJECT_GITHUB_ID = 9_999_997

      def self.call
        account = account_for_journey
        user = user_for(account)
        project_for(account, user)
      end

      def self.cleanup!
        account = Account.find_by(slug: ACCOUNT_SLUG)
        return unless account

        account.projects.destroy_all
        account.destroy!
      end

      def self.account_for_journey
        Account.find_or_create_by!(slug: ACCOUNT_SLUG) do |record|
          record.name = "Paid Journey Account"
        end
      end
      private_class_method :account_for_journey

      def self.user_for(account)
        user = User.find_or_initialize_by(email: USER_EMAIL)
        user.assign_attributes(account:, password: USER_PASSWORD, password_confirmation: USER_PASSWORD)
        user.save!
        user.account_memberships.find_or_create_by!(account:, role: :owner)
        user
      end
      private_class_method :user_for

      def self.project_for(account, user)
        token = GithubToken.find_or_create_by!(account:, name: "Paid Journey Token") do |record|
          record.created_by = user
          record.token = "ghp_#{'a' * 36}"
          record.scopes = [ "repo" ]
          record.validation_status = "validated"
        end

        Project.find_or_create_by!(account:, github_id: PROJECT_GITHUB_ID) do |record|
          record.github_token = token
          record.created_by = user
          record.name = PROJECT_NAME
          record.owner = "paid"
          record.repo = "journey"
          record.default_branch = "main"
          record.poll_interval_seconds = 60
          record.label_mappings = {}
          record.allowed_github_usernames = [ user.email ]
        end
      end
      private_class_method :project_for
    end
  end
end
