# frozen_string_literal: true

require "rails_helper"
require "rake"

# @spec FACET-CONFIDENCE-016 FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
RSpec.describe Rake::Task do
  let(:task) { described_class["facet_confidence:corpus:run"] }

  before do
    Rails.application.load_tasks unless described_class.task_defined?("facet_confidence:corpus:run")
    task.reenable
  end

  it "prints usage when the project id is omitted" do
    expect { task.invoke }
      .to raise_error(SystemExit)
      .and output(/Usage: bin\/rails/).to_stderr
  end
end
