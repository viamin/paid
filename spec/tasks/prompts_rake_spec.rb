# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "prompts:sync_defaults" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("prompts:sync_defaults")
    Rake::Task["prompts:sync_defaults"].reenable
  end

  # @spec PROMPT-DEFAULT-SYNC-005
  it "synchronizes shipped defaults and reports result counts" do
    expect { Rake::Task["prompts:sync_defaults"].invoke }
      .to output(/Prompt defaults synchronized: .*created prompts.*created versions.*unchanged/).to_stdout

    expect(Prompt.global.find_by(slug: "chat.system_prompt")).to be_present
  end
end
# rubocop:enable RSpec/DescribeClass
