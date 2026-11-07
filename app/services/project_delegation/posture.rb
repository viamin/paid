# frozen_string_literal: true

module ProjectDelegation
  # Effective delegation posture (RDR-080): one resolution every surface and
  # boundary recheck uses to answer whether a project's delegated decision
  # classes are currently delegated. No record defaults to `conservative`; a
  # disabled rollout guard or an explicit hold resolves to the conservative
  # fallback even while a delegating level stays recorded. Selection, hold,
  # and release are guarded writes that keep the immutable audit trail.
  #
  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
  class Posture
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class InvalidLevel < Error; end

    # Reviews that always stay human, whatever the posture. A delegating
    # posture keeps exactly these human; conservative (including default,
    # held, and guard-disabled fallbacks) delegates nothing, so every
    # decision class stays human there.
    DELEGATED_DECISION_CLASSES = [
      "bounded implementation choices",
      "focused follow-up recording",
      "technical-stop recovery",
      "evidence-gated issue closure",
      "bounded cycle analysis and repair"
    ].freeze
    ALWAYS_HUMAN_REVIEWS = [
      "material intent changes",
      "product decisions",
      "acceptance criteria",
      "explicit holds",
      "release and deployment",
      "settings changes",
      "merge approval"
    ].freeze
    ALL_REVIEWS = (ALWAYS_HUMAN_REVIEWS + DELEGATED_DECISION_CLASSES).freeze

    State = Data.define(:level, :source, :revision, :held, :record) do
      def delegates?
        source == :selected && level == ProjectDelegationPosture::DELEGATING_LEVEL && !held
      end

      def held?
        held
      end

      def conservative?
        !delegates?
      end

      # The reviews that remain human under this posture. Read surfaces show
      # this list next to the effective posture (RDR-080 rendered-setting
      # requirement).
      def required_human_reviews
        delegates? ? ProjectDelegation::Posture::ALWAYS_HUMAN_REVIEWS : ProjectDelegation::Posture::ALL_REVIEWS
      end
    end

    class << self
      def resolve(project)
        record = project.project_delegation_posture
        return State.new(level: ProjectDelegationPosture::CONSERVATIVE, source: :default, revision: nil,
          held: false, record: nil) if record.nil?

        State.new(
          level: delegating_level(record, project),
          source: source_for(record, project),
          revision: record.revision,
          held: record.held?,
          record: record
        )
      end

      def select(project:, user:, level:)
        ensure_permission!(project, user)
        ensure_level!(level)

        record = project.project_delegation_posture
        return record.select!(level: level, user: user) if record

        create_posture(project:, user:, level:)
      end

      def hold(project:, user:, reason: nil)
        ensure_permission!(project, user)
        record = project.project_delegation_posture
        raise Error, "project #{project.id} has no delegation posture to hold" if record.nil?

        record.hold!(user:, reason:)
      end

      def release_hold(project:, user:)
        ensure_permission!(project, user)
        record = project.project_delegation_posture
        raise Error, "project #{project.id} has no delegation posture to release" if record.nil?

        record.release_hold!(user:)
      end

      private

      def source_for(record, project)
        guards_enabled?(project) ? :selected : :guard_disabled
      end

      def delegating_level(record, project)
        return ProjectDelegationPosture::CONSERVATIVE unless guards_enabled?(project)

        record.level
      end

      def guards_enabled?(project)
        FeatureFlags.enabled?(:automation_phases, project: project) &&
          FeatureFlags.enabled?(:project_delegation, project: project)
      end

      def ensure_permission!(project, user)
        return if ProjectPolicy.new(user, project).select_delegation_posture?

        raise PermissionDenied, "You do not have permission to select the delegation posture for this project."
      end

      def ensure_level!(level)
        return if ProjectDelegationPosture::LEVELS.include?(level.to_s)

        raise InvalidLevel, "#{level.presence || "unknown"} is not a supported delegation posture."
      end

      def create_posture(project:, user:, level:)
        record = project.create_project_delegation_posture!(
          account: project.account,
          level: level.to_s,
          revision: 1,
          policy_signature: ProjectDelegationPosture.policy_signature_for(project),
          enabled_action_classes: ProjectDelegationPosture.action_classes_for(level),
          selected_by: user,
          selected_at: Time.current
        )
        Audit::RecordEvent.call(
          action: "project_delegation.selected",
          actor: user,
          subject: record,
          metadata: {
            "level" => record.level,
            "revision" => record.revision,
            "enabled_action_classes" => record.enabled_action_classes
          }
        )
        record
      end
    end
  end
end
