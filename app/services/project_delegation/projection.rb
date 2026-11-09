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

    # Lifecycle view of one bounded authorization. Mirrors the lineage rule
    # the admission contract enforces: the newest authorization for an
    # action governs, and a terminal or expired one admits nothing until a
    # new explicit authorization exists.
    AuthorizationState = Data.define(:id, :work_item_id, :action, :phase, :stop_before_phase,
      :status, :expires_at, :authority) do
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
          expires_at: expires_at&.iso8601,
          authority: authority.to_h
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

    # The effective project posture (RDR-080), shared with the selection
    # write path so read surfaces and settings cannot disagree.
    # @spec PROJECT-DELEGATION-001
    def posture
      @posture ||= ProjectDelegation::Posture.resolve(project)
    end

    # The one effective-policy answer for a phase. Read surfaces call this
    # instead of re-deriving authority from settings, grants, or labels.
    def phase_decision(phase)
      raise ArgumentError, "phase decisions require a work-item projection" unless work_item

      effective_policy_decision(phase, work_item)
    end

    # Effective-policy decision for a delegated action's owning phase.
    def action_authority(action)
      action = action.to_s
      effective_policy_decision(
        Automation::DelegatedActionAdmission::ACTION_PHASES.fetch(action), work_item, delegated_action: action
      )
    end

    # Active continuation grants covering `phase` for the projected work
    # item's chain (RDR-077 §3), resolved through the shared lookup.
    def continuation_grants(phase)
      grants_for(work_item).select { |grant| grant.covers_phase?(phase) }
    end

    # The newest bounded authorization per delegated action for the
    # projected scope: work-item scoped when a work item is given, otherwise
    # the project's governing authorizations keyed by work item and action.
    def authorizations
      @authorizations ||= begin
        records = latest_records
        preload_grants(records.map(&:issue))
        records.map { |record| state_for(record) }
      end
    end

    def authorization_for(action)
      authorizations.find { |state| state.action == action.to_s }
    end

    # The same posture signature the admission contract pins, so read
    # surfaces and boundary rechecks cannot disagree about posture.
    def posture_signature(action:)
      action = action.to_s
      @posture_signatures ||= {}
      @posture_signatures[action] ||= Automation::DelegatedActionAdmission.posture_signature_for(
        project: project, action: action
      )
    end

    # One serializable payload shared by the API and MCP surfaces.
    def to_h
      payload = {
        project_id: project.id,
        work_item_id: work_issue&.id,
        posture: posture.to_h,
        authorizations: authorizations.map(&:to_h),
        posture_signatures: AUTHORIZED_ACTIONS.to_h { |action| [ action, posture_signature(action: action) ] },
        signature: signature
      }
      payload[:expansion_guard] = ProjectDelegation::ExpansionGuard.call(project:).to_h
      payload[:phase_authority] = serialized_phase_authority if work_issue
      payload
    end

    # Digest of the projected state: stable until an authorization, the
    # effective policy, or the project posture changes.
    def signature
      Digest::SHA256.hexdigest(signature_source.to_json)
    end

    private

    def latest_records
      return [] if work_item && work_issue.nil?

      governing_records.sort_by { |record| [ record.issue_id.to_i, record.action ] }
    end

    def governing_records
      authorization_scope
        .select("DISTINCT ON (issue_id, action) bounded_delegated_actions.*")
        .order(:issue_id, :action, id: :desc)
        .includes(:issue)
    end

    def authorization_scope
      work_issue ? work_issue.bounded_delegated_actions : project.bounded_delegated_actions
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
        expires_at: record.expires_at,
        authority: effective_policy_decision(
          Automation::DelegatedActionAdmission::ACTION_PHASES.fetch(record.action, record.action), record.issue,
          delegated_action: record.action
        )
      )
    end

    def effective_policy_decision(phase, scoped_work_item, delegated_action: nil)
      key = [ phase.to_s, scoped_work_item&.id, delegated_action ]
      @phase_decisions ||= {}
      @phase_decisions[key] ||= Automation::EffectivePolicy.call(
        project: project,
        phase: phase.to_s,
        work_item: scoped_work_item,
        trigger: :automatic,
        continuation_grants: grants_for(scoped_work_item),
        rollout_enabled: rollout_enabled?,
        delegated_action: delegated_action
      )
    end

    def rollout_enabled?
      return @rollout_enabled if defined?(@rollout_enabled)

      @rollout_enabled = Automation::RolloutGuard.enabled?(project)
    end

    def grants_for(scoped_work_item)
      issue = Automation::ContinuationGrantLookup.issue_for(scoped_work_item)
      return [] unless issue

      preload_grants([ issue ]) unless @grant_chain_ids&.key?(issue.id)
      @grants_by_issue_id.values_at(*@grant_chain_ids.fetch(issue.id)).flatten
    end

    def preload_grants(issues)
      root_ids_by_issue = issues.to_h do |issue|
        roots = [ issue.id ]
        roots << issue.parent_issue_id if issue.is_pull_request? && issue.parent_issue_id.present?
        [ issue.id, roots ]
      end
      root_ids = root_ids_by_issue.values.flatten.uniq
      linked_ids = project.issues.pull_requests_only.where(parent_issue_id: root_ids)
        .pluck(:parent_issue_id, :id).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      @grant_chain_ids ||= {}
      root_ids_by_issue.each do |issue_id, roots|
        @grant_chain_ids[issue_id] = roots | roots.flat_map { |root_id| linked_ids.fetch(root_id, []) }
      end
      grant_ids = @grant_chain_ids.values.flatten.uniq
      @grants_by_issue_id = project.work_item_continuation_grants.active.where(issue_id: grant_ids).group_by(&:issue_id)
      @grants_by_issue_id.default = []
    end

    def serialized_phase_authority
      AUTHORIZED_ACTIONS.to_h { |action| [ action, action_authority(action).to_h ] }
    end

    def signature_source
      {
        posture: { level: posture.level, revision: posture.revision, policy_signature: posture.policy_signature },
        authorizations: authorizations.map(&:to_h),
        phase_authority: work_issue ? serialized_phase_authority : nil,
        posture_signatures: AUTHORIZED_ACTIONS.to_h { |action| [ action, posture_signature(action: action) ] }
      }
    end
  end
end
