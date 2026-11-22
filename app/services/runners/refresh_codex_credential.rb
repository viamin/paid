# frozen_string_literal: true

require "digest"
require "timeout"
require "tmpdir"

module Runners
  # Adapts one selected canonical record to the harness's native-store contract.
  # Provider transport and native token interpretation remain outside this adapter.
  # @spec SUBSCRIPTION-RUNNER-AUTH-007
  class RefreshCodexCredential
    TIMEOUT_SECONDS = 45
    METADATA_KEYS = %i[provider billing_mode account_id expires_at expired refreshable generation].freeze

    class Error < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("Managed Codex recovery rejected: #{reason}")
      end
    end

    def self.call(credential:, &persist)
      new(credential).call(&persist)
    end

    def initialize(credential)
      @credential = credential
    end

    def call
      # The harness exposes interruptible bounded recovery and preserves its
      # committed result. Keep subsequent canonical persistence, transaction
      # commit and private-store cleanup together against caller watchdogs.
      Thread.handle_interrupt(Timeout::Error => :never, Timeout::ExitException => :never) do
        credential.with_lock do
          original = credential.token.to_s
          source = CodexCredentials::Secret.parse(original)
          validate_source!(source)
          recover(original, source.account_id) do |native|
            raise Error, "concurrent_update" if credential.reload.revoked? || credential.token.to_s != original

            yield native
          end
        end
      end
      true
    end

    private

    attr_reader :credential

    def validate_source!(source)
      unless AgentHarness::Authentication.respond_to?(:credential_metadata) &&
          AgentHarness::Authentication.exchange_refresh_token_supported?(:codex)
        raise Error, "unsupported_refresh"
      end
      raise Error, "revoked" if credential.revoked?
      raise Error, "missing_refresh_material" unless source.codex_auth? && source.refreshable?
      raise Error, "identity_missing" unless source.account_id.is_a?(String) && source.account_id.present?
    end

    def recover(original, account_id)
      Dir.mktmpdir("paid-codex-managed-auth-") do |directory|
        path = File.join(directory, "auth.json")
        File.write(path, original, perm: 0o600)
        generation = Digest::SHA256.hexdigest(original)
        selection = AgentHarness::Authentication.credential_metadata(:codex, credential_path: path)
        validate_metadata!(selection, account_id: account_id, generation: generation, fresh: false)
        # The SDK owns an immediate region for a caller's bare watchdog before
        # native commit. Keep that watchdog deferred outside its region until
        # the returned rotation is persisted; its own typed deadline remains
        # interruptible throughout the public call.
        result = Thread.handle_interrupt(Timeout::Error => :immediate) do
          AgentHarness::Authentication.exchange_refresh_token(:codex,
            credential_path: path, expected_generation: generation,
            expected_account_id: account_id, timeout: TIMEOUT_SECONDS)
        end
        yield validated_native(result, path: path, account_id: account_id)
      end
    end

    def validated_native(result, path:, account_id:)
      unless result.is_a?(Hash) && result[:credentials].is_a?(Hash) && result[:metadata].is_a?(Hash)
        raise Error, "malformed_envelope"
      end

      native = File.binread(path)
      raise Error, "native_result_mismatch" unless JSON.parse(native) == result[:credentials]

      observed = AgentHarness::Authentication.credential_metadata(:codex, credential_path: path)
      generation = Digest::SHA256.hexdigest(native)
      validate_metadata!(observed, account_id: account_id, generation: generation, fresh: true)
      validate_metadata!(result[:metadata], account_id: account_id, generation: generation, fresh: true)
      unless observed.slice(*METADATA_KEYS) == result[:metadata].slice(*METADATA_KEYS)
        raise Error, "metadata_result_mismatch"
      end

      parsed = CodexCredentials::Secret.parse(native)
      unless parsed.codex_auth? && parsed.account_id == account_id && parsed.access_token.present? &&
          parsed.refreshable? && parsed.expires_at.present? && parsed.expires_at > Time.current
        raise Error, "unusable_native_credentials"
      end
      native
    end

    def validate_metadata!(metadata, account_id:, generation:, fresh:)
      unless metadata.is_a?(Hash) && metadata[:provider] == :codex &&
          metadata[:billing_mode] == :chatgpt_subscription && metadata[:account_id] == account_id &&
          metadata[:generation] == generation && metadata[:refreshable] == true
        raise Error, "selection_mismatch"
      end
      return unless fresh
      return if metadata[:expires_at].is_a?(Time) && metadata[:expires_at] > Time.current && metadata[:expired] == false

      raise Error, "unusable_expiry"
    end
  end
end
