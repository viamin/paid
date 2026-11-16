# frozen_string_literal: true

module StagedCloseoutAdoption
  class Enroll
    def self.call(...) = new(...).call

    def initialize(project:, actor:, enabled:)
      @project = project
      @actor = actor
      @enabled = ActiveModel::Type::Boolean.new.cast(enabled)
    end

    # @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002
    def call
      raise Error, "actor is not authorized to manage this project" unless ProjectPolicy.new(actor, project).update?

      project.with_lock do
        enrollment = project.staged_closeout_enrollment || project.build_staged_closeout_enrollment(account: project.account)
        enrollment.update!(enabled:, reviewed_by: actor, reviewed_at: Time.current, revision: enrollment.revision.to_i + (enrollment.persisted? ? 1 : 0))
        enrollment
      end
    end

    private

    attr_reader :actor, :enabled, :project
  end
end
