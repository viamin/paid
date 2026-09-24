# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-012
  # @spec APPLE-ATTEMPT-013
  # Decides whether an agent run or pull request verification result is
  # blocked by an Apple verification requirement. Blocking ties to an
  # approved committed workflow digest and its approved lifecycle gate;
  # draft workflows and advisory checks never block. A waiver releases a
  # specific required attempt so the gate evaluates the most-recent
  # approved-revision attempt that hasn't been waived.
  class GateEnforcement
    Decision = Data.define(:blocking, :reason, :gate, :attempt, :waiver) do
      def blocking?
        blocking
      end
    end

    REASONS = %w[
      satisfied
      no_approved_workflow
      draft_only
      pending_required_attempt
      all_attempts_failed_or_pending
      waived
      no_required_checks
    ].freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(
      agent_run: nil,
      pull_request: nil,
      lifecycle_gate:,
      project: nil,
      clock: Time
    )
      @agent_run = agent_run
      @pull_request = pull_request
      @lifecycle_gate = lifecycle_gate
      @project = project || @agent_run&.project || pull_request_project
      @clock = clock
    end

    def call
      return satisfy("no_approved_workflow") if project.nil?

      approved = approved_workflow
      return satisfy("no_approved_workflow") unless approved
      return satisfy("draft_only") unless approved.lifecycle_gate == @lifecycle_gate || approved.lifecycle_gate == "agent_iteration"

      required_checks = Array(approved.required_checks)
      return satisfy("no_required_checks") if required_checks.empty?

      attempts = eligible_attempts(approved)
      return block(nil) if attempts.empty?

      waiver = active_waiver_for(attempts.first)
      return satisfy("waived", waiver: waiver) if waiver

      last_attempt = attempts.first
      if last_attempt.succeeded?
        satisfy("satisfied", attempt: last_attempt)
      elsif blocking_attempt?(last_attempt)
        block(last_attempt)
      else
        satisfy("pending_required_attempt", attempt: last_attempt)
      end
    end

    private

    attr_reader :agent_run, :pull_request, :lifecycle_gate, :project

    def satisfy(reason, attempt: nil, waiver: nil)
      Decision.new(blocking: false, reason:, gate: @lifecycle_gate, attempt:, waiver:)
    end

    def block(attempt)
      Decision.new(blocking: true, reason: "pending_required_attempt", gate: @lifecycle_gate, attempt:, waiver: nil)
    end

    def approved_workflow
      project.apple_verification_workflow_revisions.approved.first
    end

    def eligible_attempts(workflow)
      relation = workflow.apple_verification_attempts
      relation = relation.where(lifecycle_gate: @lifecycle_gate)
      relation = relation.where(agent_run_id: @agent_run.id) if @agent_run
      relation = relation.where(commit_sha: pull_request_head_sha) if pull_request
      relation.order(retry_number: :desc, created_at: :desc)
    end

    def pull_request_head_sha
      return pull_request.head_sha if pull_request.respond_to?(:head_sha)
      return pull_request.head.sha if pull_request.respond_to?(:head)

      nil
    end

    def pull_request_project
      pull_request.project if pull_request&.respond_to?(:project)
    end

    def blocking_attempt?(attempt)
      return false if attempt.nil?
      return false if attempt.terminal? && attempt.status == "succeeded"

      true
    end

    # Returns the first non-expired waiver attached to the attempt, or nil
    # when the attempt has no active waiver. A waiver whose +expires_at+ has
    # passed is treated as inactive so it cannot silently release a future
    # required attempt.
    def active_waiver_for(attempt)
      return nil unless attempt

      waiver_relation = attempt.apple_verification_waivers
      return nil unless waiver_relation.respond_to?(:where)

      waiver_relation.where("expires_at > ?", current_time).first
    end

    # Resolves +now+ through whatever clock the service was constructed with.
    # The clock contract is the same as the sibling services
    # ({WorkerHealth}, {TimeoutMonitor}, {CommittedSource}): prefer
    # +current+ when available (e.g. +ActiveSupport::TimeZone+ or the
    # +Time+ class), fall back to +now+ for plain clock instances, and
    # finally to the clock value itself so a literal Time responds cleanly.
    def current_time
      return @clock.current if @clock.respond_to?(:current)
      return @clock.now if @clock.respond_to?(:now)

      @clock
    end
  end
end
