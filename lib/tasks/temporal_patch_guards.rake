# frozen_string_literal: true

namespace :temporal do
  namespace :patch_guards do
    desc "Audit Temporal workflow patch guards against the oldest running executions"
    task sweep: :environment do
      report = TemporalPatchGuards::Sweep.new.call
      puts report.to_text
    end
  end
end
