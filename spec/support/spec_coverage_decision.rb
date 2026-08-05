# frozen_string_literal: true

# Pure coverage-on/off decision extracted from spec_helper.rb so it can be
# unit-tested in-process instead of via a `bundle exec ruby` subprocess per
# matrix case. spec_helper.rb applies it; one subprocess spec still asserts the
# wiring (that requiring spec_helper actually respects it).
module SpecCoverageDecision
  module_function

  # Returns whether SimpleCov should start for this run.
  #
  # +env+ is the environment (the ENV object at runtime, or a Hash in tests).
  # +mutant_defined+ mirrors `defined?(::Mutant)` — Mutant loads spec_helper in
  # its main process and each forked worker inherits the state; whole-codebase
  # line coverage is near zero for a scoped mutation run and would trip the
  # minimum_coverage gate, so coverage is never started under Mutant.
  def call(env:, mutant_defined: false)
    return false if mutant_defined
    return env["COVERAGE"] != "false" if env.key?("COVERAGE")

    # DB-less verification runs intentionally execute a small subset of the
    # suite, so the global coverage floor creates false failures there.
    env["ALLOW_DBLESS_SPECS"] != "true"
  end
end
