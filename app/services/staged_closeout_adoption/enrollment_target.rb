# frozen_string_literal: true

module StagedCloseoutAdoption
  # Adapter bridging the Configuration::Profiles descriptor contract to the
  # per-project enrollment. Reads resolve the live value; writes stage the
  # desired value in memory; persistence writes the enrollment row itself so
  # reviewer identity, review time, and revision history keep the adoption
  # boundary semantics while the profile planner/applier transaction owns the
  # atomicity and per-level authorization.
  # @spec STAGED-CLOSEOUT-ADOPTION-008
  class EnrollmentTarget
    attr_reader :project

    def initialize(project:, actor: nil)
      @project = project
      @actor = actor
      @from = project.staged_closeout_enrollment&.enabled? || false
      @staged = nil
    end

    def enabled = @staged.nil? ? @from : @staged

    def enabled=(value)
      @staged = ActiveModel::Type::Boolean.new.cast(value)
    end

    def changed? = !@staged.nil? && @staged != @from

    def save!
      return project.staged_closeout_enrollment if @staged.nil?

      enrollment = project.class.transaction do
        locked_project = project.class.lock.find(project.id)
        enrollment = locked_project.staged_closeout_enrollment || locked_project.build_staged_closeout_enrollment(account: locked_project.account)
        enrollment.enabled = @staged
        enrollment.reviewed_by = @actor if @actor
        enrollment.reviewed_at = Time.current
        enrollment.revision = enrollment.revision.to_i + (enrollment.persisted? ? 1 : 0)
        enrollment.save!
        enrollment
      end
      project.association(:staged_closeout_enrollment).reset
      enrollment
    end

    private

    class << self
      # Reads the current enrollment value from a descriptor record: either an
      # EnrollmentTarget resolved from a profile Context or the raw project
      # passed by the legacy facade.
      def value(record)
        return record.enabled if record.is_a?(self)

        record.staged_closeout_enrollment&.enabled? || false
      end

      # Stages a descriptor write, normalizing the raw project the legacy
      # facade passes into an unreviewed (actor-less) target.
      def stage(record, value)
        target = record.is_a?(self) ? record : new(project: record)
        target.enabled = value
        target
      end
    end
  end
end
