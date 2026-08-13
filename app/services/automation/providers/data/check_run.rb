# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Normalized CI check result. Providers MAY surface richer detail
      # (annotations, logs URL, duration) via additional data classes, but
      # this shape is the minimum automation policy depends on.
      #
      # - +name+ [String] Check/job name.
      # - +status+ [Symbol] One of {STATUSES}. Represents execution
      #   progress — whether the check has finished at all.
      # - +conclusion+ [Symbol, nil] One of {CONCLUSIONS}. Nil while the
      #   check is still running.
      # - +url+ [String, nil] Optional browser-viewable URL.
      class CheckRun < ::Data.define(:name, :status, :conclusion, :url)
        STATUSES = %i[queued in_progress completed].freeze
        CONCLUSIONS = %i[
          success failure neutral cancelled skipped timed_out
          action_required stale
        ].freeze
      end
    end
  end
end
