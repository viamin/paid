# frozen_string_literal: true

module AppleVerification
  module SourceLane
    # Resolves a short-lived, repository-scoped GitHub App installation
    # reference for a committed Apple verification attempt (RDR-068 § Source
    # and Credential Transfer).
    #
    # The lane entry is a reference, never a value: the installation token
    # is delivered to the macOS guest out-of-band through the authenticated
    # {AppleVerification::GuestConnection} channel rather than embedded in
    # the manifest. The token value is never serialized into the attempt
    # record, the input manifest, the output manifest, or any artifact
    # metadata. The per-attempt mint entry point that feeds {#revoke!}'s
    # attempt-scoped cache is deferred until the guest executor transport
    # that delivers the token lands (see the segment design doc's credential
    # lane gap note).
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

      # Revokes this attempt's dedicated token at GitHub
      # (DELETE /installation/token, authenticated with the token itself) and
      # then drops the attempt-scoped cache entry. Used by the revocation
      # sweep after an attempt completes (success or failure) so a retained
      # failed VM cannot replay an old token against the GitHub API during
      # the retention window. Reads the token from the attempt-scoped cache
      # key the per-attempt mint path will write — never from the
      # project-wide shared cache {Github::AppInstallation.token_for} draws
      # from — so this never revokes a token another concurrent attempt or
      # {Project#github_credential} consumer is still relying on. Until the
      # mint entry point lands with the guest executor transport, that key
      # is never written: the read is always a miss and the revoke is a
      # safe no-op (there is nothing to revoke at GitHub). A GitHub-side
      # revoke failure is logged and swallowed: the cache entry is still
      # cleared and the credential lane entry is still considered revoked
      # locally; only the live GitHub revoke is best-effort.
      def revoke!
        return unless committed?

        installation = project.github_installation
        return unless installation

        revoke_attempt_token!(installation)
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

      def revoke_attempt_token!(installation)
        cache_key = attempt_token_cache_key(installation)
        token = Rails.cache.read(cache_key)
        return unless token

        @token_provider.new(
          installation_id: installation.github_installation_id,
          repo_full_name: project.full_name
        ).revoke(token)
      rescue Github::AppInstallation::Error => error
        Rails.logger.warn(
          message: "apple_credential.revoke_remote_failed",
          apple_verification_attempt_id: attempt.id,
          error_class: error.class.name,
          error: error.message
        )
        nil
      ensure
        Rails.cache.delete(cache_key)
      end

      def attempt_token_cache_key(installation)
        "apple_verification_credential_token:#{installation.github_installation_id}:#{attempt.id}"
      end

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
