# frozen_string_literal: true

module HealthChecks
  Finding = Data.define(:check, :scope, :severity, :message)
end
