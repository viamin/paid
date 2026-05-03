# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "screenshots:capture" do
  let(:task) { Rake::Task["screenshots:capture"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("screenshots:capture")
    task.reenable
  end

  context "when CHANGED_FILES contains no UI files" do
    around do |example|
      original = ENV["CHANGED_FILES"]
      ENV["CHANGED_FILES"] = "app/models/user.rb\nconfig/routes.rb"
      example.run
    ensure
      ENV["CHANGED_FILES"] = original
    end

    it "skips screenshot capture" do
      expect { task.invoke }.to output(/No UI-facing file changes detected/).to_stdout
    end
  end

  context "when CHANGED_FILES contains UI files" do
    let(:output_dir) { Dir.mktmpdir }

    around do |example|
      original_files = ENV["CHANGED_FILES"]
      original_dir = ENV["SCREENSHOT_OUTPUT_DIR"]
      ENV["CHANGED_FILES"] = "app/views/projects/index.html.erb"
      ENV["SCREENSHOT_OUTPUT_DIR"] = output_dir
      example.run
    ensure
      ENV["CHANGED_FILES"] = original_files
      ENV["SCREENSHOT_OUTPUT_DIR"] = original_dir
      FileUtils.rm_rf(output_dir)
    end

    it "detects UI-facing changes and runs capture" do
      allow(Screenshots::Capture).to receive(:call).and_return([])

      expect { task.invoke }.to output(/Detected 1 UI-facing file change/).to_stdout
    end
  end

  context "when CHANGED_FILES is empty" do
    let(:output_dir) { Dir.mktmpdir }

    around do |example|
      original_files = ENV["CHANGED_FILES"]
      original_dir = ENV["SCREENSHOT_OUTPUT_DIR"]
      ENV["CHANGED_FILES"] = ""
      ENV["SCREENSHOT_OUTPUT_DIR"] = output_dir
      example.run
    ensure
      ENV["CHANGED_FILES"] = original_files
      ENV["SCREENSHOT_OUTPUT_DIR"] = original_dir
      FileUtils.rm_rf(output_dir)
    end

    it "proceeds with capture without filtering" do
      allow(Screenshots::Capture).to receive(:call).and_return([])

      expect { task.invoke }.to output(/Captured 0 screenshot/).to_stdout
    end
  end
end
# rubocop:enable RSpec/DescribeClass
