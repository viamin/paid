# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # One recorded outcome for one scenario execution. Statuses:
    # passed — the live run observed the expected outcome; failed — it
    # observed something else; gap — the scenario could not be executed.
    # A criterion is satisfiable only by passed rows.
    # @spec APPLE-LIVE-002
    Evidence = Data.define(:scenario_id, :status, :detail, :references, :recorded_at) do
      def passed?
        status == :passed
      end
    end
  end
end
