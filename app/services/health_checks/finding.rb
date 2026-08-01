# frozen_string_literal: true

module HealthChecks
  # A single detected configuration problem. The stable +code+ is the
  # dedup/auto-resolve key shared with the notification pipeline. The
  # structured +title+/+description+/+remediation+/+action_url+ fields drive
  # the health page UI so it renders stable, actionable copy instead of
  # deriving labels from Ruby class names (RDR-049).
  Finding = Data.define(:code, :scope, :severity, :title, :description,
                        :remediation, :action_url, :subject_type, :subject_id,
                        :metadata) do
    SEVERITIES = %i[info warning error].freeze

    # code/scope/severity/title identify a finding; the descriptive and
    # deep-link fields are genuinely optional (a finding may have no
    # action_url), so they default rather than forcing every caller to pass nil.
    def initialize(code:, scope:, severity:, title:, description: nil,
                   remediation: nil, action_url: nil, subject_type: nil,
                   subject_id: nil, metadata: {})
      super
    end
  end
end
