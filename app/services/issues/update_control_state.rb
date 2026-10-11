# frozen_string_literal: true

module Issues
  # @spec LABEL-CONTROL-002
  class UpdateControlState
    ACTIONS = %w[pause resume dismiss_escalation skip_auto_merge hold_for_review approve_tests request_test_changes set_priority exclude_from_auto_pick clear_auto_pick_exclusion].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, action:, priority: nil, reason: nil)
      @issue = issue
      @actor = actor
      @action = action
      @priority = priority
      @reason = reason
    end

    def call
      raise ArgumentError, "Local controls require ignored label mode" unless issue.local_control_state?

      apply!
      issue
    end

    private

    attr_reader :issue, :actor, :action, :priority, :reason

    def apply!
      case action
      when "pause" then issue.update!(paused: true)
      when "resume" then issue.update!(paused: false)
      when "dismiss_escalation" then dismiss_escalation!
      when "skip_auto_merge" then issue.update!(skip_auto_merge: true)
      when "hold_for_review" then issue.update!(hold_for_review: true)
      when "approve_tests" then issue.update!(tdd_review_state: "approved")
      when "request_test_changes" then issue.update!(tdd_review_state: "changes_requested")
      when "set_priority" then issue.update!(control_priority: priority)
      when "exclude_from_auto_pick" then exclude_from_auto_pick!
      when "clear_auto_pick_exclusion" then issue.update!(auto_pick_excluded_reason: nil)
      else raise ArgumentError, "Unsupported control action: #{action}"
      end
    end

    def dismiss_escalation!
      result = PullRequests::Unblock.call(pull_request: issue, actor: actor)
      raise ArgumentError, "Cannot dismiss escalation: #{result.error}" unless result.success?
    end

    def exclude_from_auto_pick!
      raise ArgumentError, "An exclusion reason is required" if reason.blank?

      issue.update!(auto_pick_excluded_reason: reason)
    end
  end
end
