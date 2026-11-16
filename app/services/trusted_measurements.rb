# frozen_string_literal: true

require "digest"

# Trusted, allowlisted, read-only post-deploy measurements collected against
# a tenant's own live data through normal tenant-scoped database access —
# never operator-supplied SQL, control-plane execution of repository code,
# cross-tenant reads, or a bypass of normal database-role rules.
#
# A check is identified by a stable +check_key+ and a +version+. Only checks
# registered in {ALLOWLIST} may be collected; {RunCheck} and
# {TrustedMeasurementAttempt} both refuse any other key. Class names are
# resolved lazily (by name, not by constant reference) so this namespace file
# does not have to load in a particular order relative to the check classes.
module TrustedMeasurements
  ALLOWLIST = {
    "agent_planning_hold_reconciliation_closed_count" =>
      "TrustedMeasurements::Checks::PlanningHoldReconciliationClosedCount"
  }.freeze

  UnknownCheckError = Class.new(StandardError)

  def self.check_class(check_key)
    ALLOWLIST.fetch(check_key) { raise UnknownCheckError, "#{check_key.inspect} is not an allowlisted trusted measurement check" }.constantize
  end

  def self.implementation_digest(check_key)
    check = check_class(check_key)
    source_path = check.method(:call).source_location&.first
    raise UnknownCheckError, "#{check_key.inspect} does not have readable implementation source" unless source_path && File.file?(source_path)

    Digest::SHA256.file(source_path).hexdigest
  end
end
