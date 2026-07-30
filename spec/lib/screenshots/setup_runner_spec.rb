# frozen_string_literal: true

require "rails_helper"
require "shellwords"
require "screenshots/setup_runner"

RSpec.describe Screenshots::SetupRunner do
  subject(:runner) { described_class.new }

  let(:repo_path) { Dir.mktmpdir("setup-runner") }

  after do
    FileUtils.rm_rf(repo_path)
  end

  it "preserves shell command semantics for inline env assignments and redirects" do
    output_path = File.join(repo_path, "setup.out")

    runner.call(
      commands: [ %(FOO=bar sh -c 'printf "%s" "$FOO"' > #{output_path.shellescape}) ],
      repo_path: repo_path
    )

    expect(File.read(output_path)).to eq("bar")
  end

  it "preserves shell operators like && across setup commands" do
    first_path = File.join(repo_path, "first.out")
    second_path = File.join(repo_path, "second.out")

    runner.call(
      commands: [ %(printf '%s' first > #{first_path.shellescape} && printf '%s' second > #{second_path.shellescape}) ],
      repo_path: repo_path
    )

    expect(File.read(first_path)).to eq("first")
    expect(File.read(second_path)).to eq("second")
  end

  it "rejects blank setup commands" do
    expect do
      runner.call(commands: [ "   " ], repo_path: repo_path)
    end.to raise_error(ArgumentError, "Screenshot setup command cannot be blank")
  end
end
