# frozen_string_literal: true

module Automation
  module ManualStart
    # RDR-077 §3: the shared contract behind every manual-start surface (the
    # project run form, work-detail actions, and API clients). It owns the
    # applicable continuation endpoints, the effective-policy notice, the
    # notice signature used for submission-time re-evaluation, and grant
    # creation.
    #
    # @spec AUTOMATION-PHASES-004 @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-009
    # @spec AUTOMATION-PHASES-010 @spec AUTOMATION-PHASES-011 @spec AUTOMATION-PHASES-012
    class Plan
      class Error < StandardError; end
      # The actor may not delegate the actions the requested endpoint covers.
      class PermissionDenied < Error; end
      # The requested endpoint is not offered for this action.
      class EndpointNotApplicable < Error; end
      # Continuation must attach to a durable issue or pull-request work item.
      class WorkItemRequired < Error; end

      attr_reader :continuation_selected, :endpoint, :goal, :phase, :project, :user

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, phase:, goal: nil, endpoint: nil, continuation_selected: false)
        @project = project
        @user = user
        @phase = phase.to_s
        @goal = goal
        @endpoint = resolve_endpoint(endpoint)
        @continuation_selected = continuation_selected ? true : false
      end

      def call
        validate_endpoint!
        ensure_delegation_permitted! if continuation_selected
        self
      end

      # Endpoint choices applicable to this action's phase; the action's own
      # phase is the default when it exists.
      # @spec AUTOMATION-PHASES-001
      def endpoints
        Automation::Phases.endpoints_for(phase)
      end

      def default_endpoint
        endpoints.include?(phase) ? phase : endpoints.first
      end

      # @spec AUTOMATION-PHASES-010
      def notice
        @notice ||= EffectivePolicyNotice.new(
          project: project,
          phase: phase,
          endpoint: endpoint,
          continuation_selected: continuation_selected
        )
      end

      # Client-refresh payload: the run form's goal toggle re-renders the
      # continuation section from this without a server round trip. The policy
      # signature is deliberately absent; submission re-evaluates it
      # server-side against the then-current signature.
      # @spec AUTOMATION-PHASES-004 @spec AUTOMATION-PHASES-010
      def payload
        {
          default_endpoint: default_endpoint,
          endpoints: endpoints.map { |endpoint| { value: endpoint, label: Automation::Phases.label(endpoint) } },
          notices: notices
        }
      end

      def signature
        notice.signature
      end

      # @spec AUTOMATION-PHASES-011
      def policy_changed_since?(submitted_signature)
        submitted_signature.blank? || submitted_signature != signature
      end

      # @spec AUTOMATION-PHASES-005
      def build_grant(issue:, start_phase: phase)
        return nil unless continuation_selected
        raise WorkItemRequired, "Select an issue or pull request to authorize automatic continuation." unless issue

        ensure_delegation_permitted!

        WorkItemContinuationGrant.create!(
          project: project,
          issue: issue,
          start_phase: start_phase,
          endpoint: endpoint,
          source: "manual_start",
          created_by: user
        )
      end

      private

      def notices
        endpoints.index_with { |endpoint| notice_for(endpoint) }
      end

      def notice_for(endpoint)
        EffectivePolicyNotice.new(project: project, phase: phase, endpoint: endpoint).selection_summary
      end

      def resolve_endpoint(endpoint)
        requested = endpoint.to_s.presence
        return requested if requested

        Automation::Phases.endpoints_for(phase).then { |choices| choices.include?(phase) ? phase : choices.first }
      end

      def validate_endpoint!
        return if endpoints.include?(endpoint)

        raise EndpointNotApplicable, "Choose a continuation endpoint offered for this action."
      end

      # Continuation delegates every phase it covers. A merge endpoint keeps a
      # distinct permission for callers and audit messages that need to name it.
      # @spec AUTOMATION-PHASES-009
      def ensure_delegation_permitted!
        raise PermissionDenied, permission_message unless delegation_permitted?
      end

      def delegation_permitted?
        return merge_delegation_permitted? if endpoint == Automation::Phases::MERGE

        ProjectPolicy.new(user, project).delegate_automation?
      end

      def merge_delegation_permitted?
        ProjectPolicy.new(user, project).delegate_merge?
      end

      def permission_message
        if endpoint == Automation::Phases::MERGE
          "You do not have permission to delegate merging for this project."
        else
          "You do not have permission to delegate this action for the project."
        end
      end
    end
  end
end
