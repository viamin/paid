# frozen_string_literal: true

module ProjectDelegation
  # RDR-080 surface parity: the one shared delegation read model. Settings,
  # Inbox, API, and MCP surfaces read delegation state and phase authority
  # through this projection and Automation::EffectivePolicy; no surface
  # infers authority from a label, a stale approval, queue state, or local
  # UI state. Write boundaries (queue, dequeue, retry, follow-up, closeout,
  # repair) keep using Automation::DelegatedActionAdmission; this class is
  # read-only and never grants anything.
  #
  # @spec PROJECT-DELEGATION-005
  class Projection
    AUTHORIZED_ACTIONS = BoundedDelegatedAction::ACTIONS.freeze
    RECENT_LIMIT = 200

    # Lifecycle view of one bounded authorization. Mirrors the lineage rule
    # the admission contract enforces: the newest authorization for an
    # action governs, and a terminal or expired one admits nothing until a
    # new explicit authorization exists.
    AuthorizationState = Data.define(:id, :work_item_id, :action, :phase, :stop_before_phase,
      :status, :expires_at) do
      def in_force?
        status == "active" && expires_at.present? && expires_at > Time.current
      end

      def expired?
        status == "active" && expires_at.present? && expires_at <= Time.current
      end

      def to_h
        {
          id: id,
          work_item_id: work_item_id,
          action: action,
          phase: phase,
          stop_before_phase: stop_before_phase,
          status: status,
          in_force: in_force?,
          expires_at: expires_at&.iso8601
        }
      end
    end

    class << self
      def for_project(project)
        new(project: project)
      end

      def for_work_item(project:, work_item:)
        new(project: project, work_item: work_item)
      end
    end

    def initialize(project:, work_item: nil)
      @project = project
      @work_item = work_item
    end

    attr_reader :project, :work_item

    # The one effective-policy answer for a phase. Read surfaces call this
    # instead of re-deriving authority from settings, grants, or labels.
    def phase_decision(phase)
      Automation::EffectivePolicy.call(
        project: project, phase: phase.to_s, work_item: work_item, trigger: :automatic
      )
    end

    # Effective-policy decision for a delegated action's owning phase.
    def action_authority(action)
      phase_decision(Automation::DelegatedActionAdmission::ACTION_PHASES.fetch(action.to_s))
    end

    # Active continuation grants covering `phase` for the projected work
    # item's chain (RDR-077 §3), resolved through the shared lookup.
    def continuation_grants(phase)
      Automation::ContinuationGrantLookup.resolve(project: project, phase: phase, work_item: work_item)
    end

    # The newest bounded authorization per delegated action for the
    # projected scope: work-item scoped when a work item is given, otherwise
    # the project's recent authorizations keyed by work item and action.
    def authorizations
      @authorizations ||= latest_records.map { |record| state_for(record) }
    end

    def authorization_for(action)
      authorizations.find { |state| state.action == action.to_s }
    end

    # The same posture signature the admission contract pins, so read
    # surfaces and boundary rechecks cannot disagree about posture.
    def posture_signature(action:)
      Automation::DelegatedActionAdmission.posture_signature_for(project: project, action: action.to_s)
    end

    # One serializable payload shared by the API and MCP surfaces.
    def to_h
      {
        project_id: project.id,
        work_item_id: work_issue&.id,
        authorizations: authorizations.map(&:to_h),
        phase_authority: AUTHORIZED_ACTIONS.to_h { |action| [ action, action_authority(action).to_h ] },
        posture_signatures: AUTHORIZED_ACTIONS.to_h { |action| [ action, posture_signature(action: action) ] },
        signature: signature
      }
    end

    # Digest of the projected state: stable until an authorization, the
    # effective policy, or the project posture changes.
    def signature
      Digest::SHA256.hexdigest(signature_source.to_json)
    end

    private

    def latest_records
      scope = work_issue ? work_issue.bounded_delegated_actions.order(id: :desc) : recent_project_authorizations
      grouped = scope.each_with_object({}) do |record, latest|
        key = [ record.issue_id, record.action ]
        latest[key] ||= record
      end
      grouped.values.sort_by { |record| [ record.issue_id.to_i, record.action ] }
    end

    def recent_project_authorizations
      project.bounded_delegated_actions.order(id: :desc).limit(RECENT_LIMIT)
    end

    # A work item may be the issue itself or a run; the projection follows
    # the same resolution the continuation-grant lookup uses.
    def work_issue
      return nil if work_item.nil?

      @work_issue ||= Automation::ContinuationGrantLookup.issue_for(work_item)
    end

    def state_for(record)
      AuthorizationState.new(
        id: record.id,
        work_item_id: record.issue_id,
        action: record.action,
        phase: Automation::DelegatedActionAdmission::ACTION_PHASES.fetch(record.action, record.action),
        stop_before_phase: record.evidence.to_h["stop_before_phase"],
        status: record.status,
        expires_at: record.expires_at
      )
    end

    def signature_source
      {
        authorizations: authorizations.map(&:to_h),
        phase_authority: AUTHORIZED_ACTIONS.to_h { |action| [ action, action_authority(action).to_h ] },
        posture_signatures: AUTHORIZED_ACTIONS.to_h { |action| [ action, posture_signature(action: action) ] }
      }
    end
  end
end
