# frozen_string_literal: true

require "rails_helper"
require "screenshots/setup_runner"

RSpec.describe Screenshots::SetupRunner do
  subject(:runner) { described_class.new }

  let(:repo_path) { "/tmp/repo" }

  it "executes setup commands without invoking a shell" do
    status = instance_double(Process::Status, success?: true)

    allow(Open3).to receive(:capture3).and_return([ "", "", status ])

    runner.call(commands: [ "bin/rails db:prepare RAILS_ENV=test" ], repo_path: repo_path)

    expect(Open3).to have_received(:capture3).with(
      "bin/rails",
      "db:prepare",
      "RAILS_ENV=test",
      chdir: repo_path
    )
  end

  it "preserves quoted arguments when splitting commands" do
    status = instance_double(Process::Status, success?: true)

    allow(Open3).to receive(:capture3).and_return([ "", "", status ])

    runner.call(commands: [ %(bin/rails runner "puts 'hello world'") ], repo_path: repo_path)

    expect(Open3).to have_received(:capture3).with(
      "bin/rails",
      "runner",
      "puts 'hello world'",
      chdir: repo_path
    )
  end

  it "rejects blank setup commands" do
    expect do
      runner.call(commands: [ "   " ], repo_path: repo_path)
    end.to raise_error(ArgumentError, "Screenshot setup command cannot be blank")
  end
end
