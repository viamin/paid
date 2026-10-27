# frozen_string_literal: true

module Inbox
  # Chooses a manual-review recovery from persisted lifecycle provenance. Stop
  # text is evidence for an operator, not an authorization to start work.
  # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    ENHANCEMENT_REASON_PREFIXES = [
      "Paid reached the configured enhancement-round limit.",
      "Paid reached the configured limit of enhancement re-evaluation rounds.",
      "Paid could not validate the enhancement agent's structured output.",
      "Structured output failed validation.",
      "Round limit reached."
    ].freeze
    Dependency = Data.define(:label, :url)
    Result = Data.define(:causes, :action, :goal, :dependencies)

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      causes = detected_causes
      Result.new(causes: causes.presence || [ :unknown ], action: action_for(causes),
        goal: goal_for(causes), dependencies: dependencies)
    end

    private

    attr_reader :issue

    def detected_causes
      [].tap do |causes|
        causes << :reopen_review if issue.reopen_review_pending?
        causes << :dependency_wait if dependencies.any?
        causes << :scanner_recurrence if scanner_recurrence?
        causes << :technical_recovery if technical_run?
        causes << :enhancement if enhancement_run?
      end
    end

    def action_for(causes)
      return :wait_for_dependency if causes.include?(:dependency_wait)
      return :resume_scanner_remediation if causes.include?(:scanner_recurrence)
      return :validate_reopen_intent if causes.include?(:reopen_review)
      return technical_action if causes.include?(:technical_recovery)
      return :retry_enhancement if causes.include?(:enhancement)

      :investigate
    end

    def goal_for(causes)
      return "create_pr" if causes.include?(:scanner_recurrence)
      return latest_goal if causes.include?(:technical_recovery)
      return "enhance_issue" if causes.intersect?([ :reopen_review, :enhancement ])
    end

    def dependencies
      @dependencies ||= local_dependencies + deployment_dependencies + external_dependencies
    end

    def local_dependencies
      issue.blocking_issues.map { |target| Dependency.new("##{target.github_number} #{target.title}", target.github_url) }
    end

    def deployment_dependencies
      issue.blocking_deployment_dependencies.map do |dependency|
        target = dependency.depends_on_issue
        Dependency.new("##{target.github_number} #{target.title} (awaiting deployment)", target.github_url)
      end
    end

    def external_dependencies
      issue.blocking_external_dependencies.map do |dependency|
        Dependency.new("#{dependency.external_ref} (external dependency)", "https://github.com/#{dependency.external_ref.sub("#", "/issues/")}")
      end
    end

    def scanner_recurrence?
      Issues::CloseoutStatus.scanner_verification_blockers(issue).any? { |blocker| blocker.code == :scanner_verification_failed }
    end

    def enhancement_run?
      latest_goal == "enhance_issue" ||
        ENHANCEMENT_REASON_PREFIXES.any? { |prefix| issue.manual_review_reason.to_s.start_with?(prefix) }
    end

    def technical_run?
      latest_goal.in?(%w[analyze_issue create_pr])
    end

    def technical_action
      latest_goal == "analyze_issue" ? :retry_analysis : :resume_implementation
    end

    def latest_goal
      @latest_goal ||= issue.agent_runs.order(created_at: :desc).limit(1).pick(:goal)
    end
  end
end
