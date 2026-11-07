# frozen_string_literal: true

module ProjectDelegation
  # The authorized posture selection write path (RDR-080): only an owner or
  # project admin may select, broadening requires both rollout guards,
  # narrowing back to conservative always stays available as the rollback
  # path, and every selection bumps the revision and records an immutable
  # audit event naming the actor, project, revision, and enabled action
  # classes. A later broadening never rewrites the history an admission
  # pinned: it only produces a new revision.
  # Intentionally exceeds the ~100-line class target: the guard checks, the
  # locked persist, and the audit record are one admission transaction and
  # read clearer together than as single-caller extractions.
  #
  # @spec PROJECT-DELEGATION-001
  class SelectPosture
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class GuardDisabled < Error; end
    class UnknownLevel < Error; end

    GUARD_MESSAGE = "Delegation is not enabled for this project yet; only the conservative posture is available."

    def self.call(...)
      new(...).call
    end

    def initialize(project:, actor:, level:)
      @project = project
      @actor = actor
      @level = level.to_s
    end

    def call
      ensure_level!
      ensure_authorized!
      ensure_guard_permits!

      _, record = persist_with_audit
      project.delegation_posture = record

      Posture.resolve(project)
    end

    private

    attr_reader :project, :actor, :level

    def ensure_level!
      raise UnknownLevel, "#{level} is not a supported delegation posture." unless Posture::LEVELS.include?(level)
    end

    def ensure_authorized!
      return if ProjectPolicy.new(actor, project).select_delegation_posture?

      raise PermissionDenied, "You do not have permission to select the delegation posture for this project."
    end

    # Broadening requires the capability guards; narrowing to the default
    # stays available so rollback is never blocked by a disabled flag.
    def ensure_guard_permits!
      return if level == Posture::CONSERVATIVE
      return if Posture.guards_enabled?(project)

      raise GuardDisabled, GUARD_MESSAGE
    end

    def persist
      if (record = ProjectDelegationPosture.find_by(project: project))
        previous_level = nil
        record.with_lock do
          previous_level = record.level
          apply_selection(record)
        end
        [ previous_level, record ]
      else
        record = ProjectDelegationPosture.create!(
          account: project.account,
          project: project,
          revision: 1,
          **selection_attrs
        )
        [ Posture::CONSERVATIVE, record ]
      end
    end

    def persist_with_audit
      ProjectDelegationPosture.transaction do
        previous_level, record = persist
        audit(record, previous_level)
        [ previous_level, record ]
      end
    end

    def apply_selection(record)
      record.update!(revision: record.revision.to_i + 1, **selection_attrs)
    end

    def selection_attrs
      {
        level: level,
        enabled_action_classes: Posture.delegated_classes(level),
        policy_signature: Posture.policy_signature(project),
        selected_by: actor
      }
    end

    # Immutable audit event: the actor, project, revision, and enabled action
    # classes of this selection. Audit history survives rollback and is never
    # rewritten by a later selection.
    def audit(record, previous_level)
      Audit::RecordEvent.call(
        action: "project_delegation.posture_selected",
        actor: actor,
        subject: project,
        metadata: {
          "project_id" => project.id,
          "project_name" => project.full_name,
          "level" => record.level,
          "previous_level" => previous_level,
          "revision" => record.revision,
          "enabled_action_classes" => record.enabled_action_classes,
          "policy_signature" => record.policy_signature,
          "guards" => {
            "automation_phases" => Automation::RolloutGuard.enabled?(project),
            "project_delegation" => FeatureFlags.enabled?(:project_delegation, project:)
          }
        }
      )
    end
  end
end
