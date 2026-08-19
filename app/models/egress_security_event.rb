# frozen_string_literal: true

# Audit-trail record for blocked egress attempts and redacted secret-extraction
# blocks reported by the agent container egress gateway or brokered-research
# service.
#
# Records are immutable from the tenant perspective — created by the gateway
# code path that observes the deny and never edited by tenant users. The
# `redacted_evidence` column carries fingerprints or redacted snippets only;
# raw secret material never reaches this table.
class EgressSecurityEvent < ApplicationRecord
  include TenantScoped

  EVENT_KINDS = %w[denied_egress redacted_secret_extraction allowlist_match].freeze
  SEVERITIES = %w[info warn critical].freeze
  SOURCE_LAYERS = %w[gateway broker firewall].freeze
  SCHEMES = EgressAllowlistEntry::SCHEMES

  belongs_to :project, optional: true
  belongs_to :agent_run, optional: true
  belongs_to :egress_allowlist_entry, optional: true

  validates :event_kind, presence: true, inclusion: { in: EVENT_KINDS }
  validates :severity, presence: true, inclusion: { in: SEVERITIES }
  validates :source_layer, presence: true, inclusion: { in: SOURCE_LAYERS }
  validates :occurred_at, presence: true
  validates :scheme, inclusion: { in: SCHEMES, allow_nil: true }
  validate :destination_port_in_range, if: -> { destination_port.present? }
  validate :project_belongs_to_account, if: -> { project.present? }
  validate :agent_run_belongs_to_project, if: -> { agent_run.present? && project.present? }

  scope :denied, -> { where(event_kind: "denied_egress") }
  scope :redacted, -> { where(event_kind: "redacted_secret_extraction") }
  scope :for_run, ->(agent_run) { where(agent_run: agent_run) }
  scope :for_project, ->(project) { where(project: project) }
  scope :recent, -> { order(occurred_at: :desc) }

  def denied_egress?
    event_kind == "denied_egress"
  end

  def redacted_extraction?
    event_kind == "redacted_secret_extraction"
  end

  def critical?
    severity == "critical"
  end

  def to_audit_line
    line = {
      event_kind: event_kind,
      severity: severity,
      source_layer: source_layer,
      destination_host: destination_host,
      destination_port: destination_port,
      scheme: scheme,
      matched_rule: matched_rule,
      redacted_evidence: redacted_evidence,
      occurred_at: occurred_at
    }
    line.delete_if { |_key, value| value.nil? }
    line
  end

  private

  def destination_port_in_range
    return if destination_port.between?(1, 65_535)

    errors.add(:destination_port, "must be between 1 and 65535")
  end

  def project_belongs_to_account
    return unless project && account_id

    if project.account_id != account_id
      errors.add(:project, "must belong to the same account")
    end
  end

  def agent_run_belongs_to_project
    return unless agent_run.project_id && project_id

    if agent_run.project_id != project_id
      errors.add(:agent_run, "must belong to the same project")
    end
  end
end
