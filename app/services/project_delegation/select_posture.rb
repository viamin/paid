# frozen_string_literal: true

module ProjectDelegation
  # Authorized selection of a project's delegation posture.
  # Only project owners and admins may call this service.
  # The service records an immutable audit event and updates the project state.
  #
  # @spec PROJECT-DELEGATION-001
  class SelectPosture
    attr_reader :project, :actor, :posture, :enabled_actions

    def initialize(project:, actor:, posture:, enabled_actions: {}, policy_signature: nil)
      @project = project
      @actor = actor
      @posture = posture
      @enabled_actions = enabled_actions
      @policy_signature = policy_signature
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      update_project
      record_audit_event
      success
    rescue => e
      failure(e)
    end

    private

    attr_reader :policy_signature

    def validate!
      raise ArgumentError, "posture must be one of #{Project::DELEGATION_POSTURES.inspect}" \
        unless Project::DELEGATION_POSTURES.include?(posture)
      raise ArgumentError, "actor must be a User" unless actor.is_a?(User)
      raise ArgumentError, "project must be a Project" unless project.is_a?(Project)
    end

    def update_project
      project.with_lock do
        project.update!(
          delegation_posture: posture,
          delegation_posture_selected_by: actor,
          delegation_posture_selected_at: Time.current,
          delegation_policy_signature: policy_signature,
          delegation_enabled_actions: enabled_actions
        )
      end
    end

    def record_audit_event
      ProjectDelegationEvent.record_posture_selection(
        project:,
        posture:,
        actor:,
        policy_signature:,
        metadata: {
          "enabled_actions" => enabled_actions
        }
      )
    end

    def success
      OpenStruct.new(success?: true, project:, error: nil)
    end

    def failure(error)
      OpenStruct.new(success?: false, project:, error:)
    end
  end
end
