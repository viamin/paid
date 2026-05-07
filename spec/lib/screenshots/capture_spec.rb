# frozen_string_literal: true

require "rails_helper"
require "screenshots/capture"

RSpec.describe Screenshots::Capture do
  let(:output_dir) { Dir.mktmpdir }
  let(:target) do
    Screenshots::CaptureTargets::Target.new(
      slug: "project_show",
      path_builder: "/projects/1",
      requires_auth: true
    )
  end
  let(:run_result) do
    Screenshots::CaptureOrchestrator::RunResult.new(
      captures: [
        Screenshots::CaptureOrchestrator::CaptureResult.new("project_show", "#{output_dir}/project_show.png", true, nil)
      ],
      failures: []
    )
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  it "passes changed files into target resolution and returns captured paths" do
    allow(Screenshots::CaptureTargets).to receive(:call).and_return([ target ])
    allow(Screenshots::CaptureOrchestrator).to receive(:call).and_return(run_result)

    result = described_class.call(
      output_dir: output_dir,
      changed_files: [ "app/views/projects/show.html.erb" ]
    )

    expect(result).to eq([ "#{output_dir}/project_show.png" ])
    expect(Screenshots::CaptureTargets).to have_received(:call).with(
      changed_files: [ "app/views/projects/show.html.erb" ]
    )
  end

  it "raises a formatted error when orchestrated capture reports failures" do
    allow(Screenshots::CaptureTargets).to receive(:call).and_return([ target ])
    allow(Screenshots::CaptureOrchestrator).to receive(:call).and_return(
      Screenshots::CaptureOrchestrator::RunResult.new(
        captures: [],
        failures: [ "project_show (/projects/1): boom" ]
      )
    )

    expect {
      described_class.call(output_dir: output_dir, changed_files: [])
    }.to raise_error(RuntimeError, /project_show .* boom/)
  end
end
