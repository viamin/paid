# frozen_string_literal: true

module Screenshots
  module SeedData
    # Minimal, isolated data for Paid's browser-verification pilot. The broader
    # screenshot seed remains responsible for screenshot-gallery coverage.
    # Ownership of the seeded account is proven only by the persisted
    # seed_owner marker; identity collisions are refused, never adopted.
    # @spec LIVE-PREVIEW-012
    class PaidJourney
      class AccountCollision < StandardError; end
      class IdentityCollision < StandardError; end

      ACCOUNT_SLUG = "paid-journey-account".freeze
      SEED_OWNER = "paid-journey".freeze
      USER_EMAIL = "paid-journey@example.com".freeze
      USER_PASSWORD = "paid-journey-password-123".freeze
      PROJECT_NAME = "Paid Journey Project".freeze
      PROJECT_GITHUB_ID = 9_999_997
      JOURNEY_ACCOUNT_LOCK = 1_339_487_214

      def self.call
        Account.transaction do
          lock_journey_account!
          account = existing_journey_account
          ensure_account_available!(account)
          ensure_identity_available!(account)
          account ||= account_for_journey
          ensure_account_available!(account)
          user = user_for(account)
          project_for(account, user)
        end
      end

      def self.cleanup!
        Account.transaction do
          lock_journey_account!
          account = Account.find_by(slug: ACCOUNT_SLUG, seed_owner: SEED_OWNER)
          next unless account

          account.projects.destroy_all
          account.destroy!
        end
      end

      def self.account_for_journey
        Account.find_or_create_by!(slug: ACCOUNT_SLUG) do |record|
          record.name = "Paid Journey Account"
          record.seed_owner = SEED_OWNER
        end
      end
      private_class_method :account_for_journey

      def self.existing_journey_account
        Account.find_by(slug: ACCOUNT_SLUG)
      end
      private_class_method :existing_journey_account

      def self.ensure_account_available!(account)
        return if account.nil?
        return if account.slug == ACCOUNT_SLUG && account.seed_owner == SEED_OWNER

        raise AccountCollision, "#{ACCOUNT_SLUG} is not a journey account"
      end
      private_class_method :ensure_account_available!

      def self.lock_journey_account!
        Account.connection.execute("SELECT pg_advisory_xact_lock(#{JOURNEY_ACCOUNT_LOCK})")
      end
      private_class_method :lock_journey_account!

      def self.ensure_identity_available!(account)
        user = User.find_by(email: USER_EMAIL)
        return if user.nil? || user.account_id == account&.id

        raise IdentityCollision, "#{USER_EMAIL} belongs to another account"
      end
      private_class_method :ensure_identity_available!

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
