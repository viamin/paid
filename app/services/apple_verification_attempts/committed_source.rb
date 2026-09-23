# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-007
  # Mints a short-lived, read-only GitHub App installation credential for an
  # Apple verification attempt that targets a committed commit. The
  # credential is scoped read-only to the target repository and delivered
  # through Paid's existing credential lane — it is never persisted in
  # repository configuration, artifacts, VM images, or host-service
  # arguments. This service is the control-plane boundary that owns the
  # "exactly one fresh credential per attempt" guarantee and rejects reuse
  # beyond its expiry.
  class CommittedSource
    DEFAULT_TTL_SECONDS = 15 * 60

    Result = Data.define(:expires_at, :installation_id, :repository_full_name, :commit_sha, :lane_entry)

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      attempt:,
      credential_lane: nil,
      ttl_seconds: DEFAULT_TTL_SECONDS,
      clock: Time
    )
      @attempt = attempt
      @credential_lane = credential_lane || AppleVerification::SourceLane::CredentialLane.new(attempt:)
      @ttl_seconds = ttl_seconds
      @clock = clock
    end

    # Issues (or refreshes) a credential for the attempt's commit. The
    # credential is delivered through the lane and must NEVER be persisted
    # on the attempt record; this method only returns the in-memory
    # descriptor callers use to attach the token to the input manifest.
    # The descriptor's +lane_entry+ is the reference-only credentials
    # lane entry ({CredentialLane.lane_entry}) the caller appends to the
    # input manifest's credentials lane — it carries no token value.
    def call
      raise ArgumentError, "attempt is not a committed-source attempt" unless committed?

      lane_result = @credential_lane.call
      Result.new(
        expires_at: current_time + @ttl_seconds.seconds,
        installation_id: lane_result.installation_id,
        repository_full_name: lane_result.repo_full_name,
        commit_sha: @attempt.commit_sha,
        lane_entry: AppleVerification::SourceLane::CredentialLane.lane_entry(lane_result)
      )
    end

    # Revokes the cached credential for this attempt. Idempotent — repeat
    # calls are a no-op so partial-failure paths can call this without
    # worrying about double-revoke noise.
    def revoke
      @credential_lane.revoke!
    end

    private

    def committed?
      @attempt.commit_sha.present?
    end

    def current_time
      return @clock.current if @clock.respond_to?(:current)
      return @clock.now if @clock.respond_to?(:now)

      @clock
    end
  end
end
