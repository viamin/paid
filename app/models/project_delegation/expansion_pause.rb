# frozen_string_literal: true

module ProjectDelegation
  # An unresolved RDR-080 expansion pause: a material reversal, a security,
  # tenant, or trust breach, or missing metric evidence. While unresolved it
  # keeps the affected project's effective posture `conservative` and blocks
  # broadening; a human records the resolution.
  #
  # @spec PROJECT-DELEGATION-007
  class ExpansionPause < ApplicationRecord
    REASONS = %w[material_reversal security_breach tenant_breach trust_breach missing_evidence].freeze

    belongs_to :account
    belongs_to :project
    belongs_to :paused_by, class_name: "User", optional: true
    belongs_to :resolved_by, class_name: "User", optional: true

    validates :reason, presence: true, inclusion: { in: REASONS }
    validates :posture_before, presence: true, inclusion: { in: PilotMetric::POSTURES }
    validate :resolution_names_its_actor

    scope :unresolved, -> { where(resolved_at: nil) }

    def self.unresolved_for(project)
      where(project:).unresolved.order(id: :desc)
    end

    def unresolved?
      resolved_at.nil?
    end

    private

    def resolution_names_its_actor
      return if resolved_at.blank? && resolved_by_id.blank?
      return if resolved_at.present? && resolved_by_id.present?

      errors.add(:resolved_by, "must accompany the resolution timestamp")
    end
  end
end
