# frozen_string_literal: true

module AppleVerification
  module SourceLane
    # Resolves a short-lived, repository-scoped GitHub App installation
    # reference for a committed Apple verification attempt (RDR-068 § Source
    # and Credential Transfer).
    #
    # The lane entry is a reference, never a value: the resolved installation
    # token is fetched through {Github::AppInstallation} at manifest-build time
    # and is delivered to the macOS guest through the authenticated
    # {AppleVerification::GuestConnection} channel rather than embedded in the
    # manifest. The token value is never serialized into the attempt record,
    # the input manifest, the output manifest, or any artifact metadata.
    #
    # @spec APPLE-TRANSFER-001
    class CredentialLane
      Result = Data.define(:installation_id, :repository_id, :repo_full_name, :ttl_seconds)

      InstallationUnavailableError = Class.new(StandardError)
      AccountMismatchError = Class.new(StandardError)
      MissingCommitError = Class.new(StandardError)
      InvalidInstallationError = Class.new(StandardError)

      DEFAULT_TTL_SECONDS = Github::AppInstallation::TOKEN_TTL.to_i

      def self.call(...)
        new(...).call
      end

      def initialize(attempt:, token_provider: Github::AppInstallation)
        @attempt = attempt
        @token_provider = token_provider
      end

      # Returns a lane-reference describing the GitHub App installation that
      # the guest executor can use to fetch the short-lived read-only
      # installation token. The token value is intentionally not returned
      # alongside the reference; the executor fetches it through its own
      # authenticated channel after manifest validation.
      def call
        raise MissingCommitError, "committed attempts must bind a commit_sha" unless committed?

        installation = resolve_installation!
        validate_installation!(installation)
        Result.new(
          installation_id: installation.github_installation_id,
          repository_id: project.github_id,
          repo_full_name: project.full_name,
          ttl_seconds: DEFAULT_TTL_SECONDS
        )
      end

      # Mints the short-lived token through the configured provider. Returns
      # the raw token value plus the resolved installation reference; the
      # caller (typically the guest executor transport) is responsible for
      # never persisting the token value. Used by the revoke path below and
      # by spec helpers that exercise the boundary.
      def mint_token!
        raise MissingCommitError, "committed attempts must bind a commit_sha" unless committed?

        installation = resolve_installation!
        validate_installation!(installation)
        @token_provider.token_for(
          installation_id: installation.github_installation_id,
          repo_full_name: project.full_name
        )
      end

      # Revokes the cached GitHub App installation token at GitHub
      # (DELETE /installation/token, authenticated with the token itself) and
      # then drops the local cache entry. Used by the revocation sweep after
      # an attempt completes (success or failure) so a retained failed VM
      # cannot replay an old token against the GitHub API during the retention
      # window. A GitHub-side revoke failure is logged and swallowed: the
      # cache entry is still cleared, the credential lane entry is still
      # revoked locally, and the audit event is still recorded; only the live
      # GitHub revoke is best-effort because the cache TTL is shorter than
      # GitHub's 1-hour token TTL and a cache miss cannot be revoked remotely.
      def revoke!
        return unless committed?

        installation = project.github_installation
        return unless installation

        @token_provider.revoke_token(
          installation_id: installation.github_installation_id,
          repo_full_name: project.full_name
        )
      rescue Github::AppInstallation::Error => error
        Rails.logger.warn(
          message: "apple_credential.revoke_remote_failed",
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        nil
      end

      # Renders the lane entry used by {AppleVerificationWorkers::InputManifest}.
      # The locator carries only reference data (no token value) and is
      # validated by the manifest's own shape check before serialization.
      def self.lane_entry(result)
        {
          "lane" => "credentials",
          "kind" => "github_app_installation",
          "locator" => {
            "installation_id" => result.installation_id,
            "repository_id" => result.repository_id,
            "repo_full_name" => result.repo_full_name,
            "ttl_seconds" => result.ttl_seconds
          }
        }
      end

      private

      attr_reader :attempt, :token_provider

      def committed?
        attempt.commit_sha.present?
      end

      def project
        attempt.project
      end

      def resolve_installation!
        installation = project.github_installation
        raise InstallationUnavailableError, "no GitHub App installation for project #{project.id}" unless installation

        installation
      end

      def validate_installation!(installation)
        raise InvalidInstallationError, "GitHub App installation is suspended" if installation.suspended?
        raise InvalidInstallationError, "GitHub App installation is revoked" if installation.revoked?
        raise AccountMismatchError, "GitHub App installation does not belong to the project account" if installation.account_id != project.account_id

        return if installation.covers_repository?(project.full_name)

        raise InvalidInstallationError, "GitHub App installation does not cover #{project.full_name}"
      end
    end
  end
end
