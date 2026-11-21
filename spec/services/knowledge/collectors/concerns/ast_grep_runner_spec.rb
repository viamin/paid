# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::Concerns::AstGrepRunner, :no_db do
  let(:collector_class) do
    Class.new(Knowledge::BaseCollector) { include Knowledge::Collectors::Concerns::AstGrepRunner }
  end
  let(:collector) { collector_class.new(project: nil, project_version: nil, collector_run: nil, options: { partial_collection: true }) }

  def parse
    collector.send(:run_ast_grep, "class $NAME", "Ruby", paths: [ "example.rb" ])
  end

  def tool_result(stdout: "", exit_code: 0)
    status = instance_double(Process::Status, success?: exit_code.zero?, exitstatus: exit_code)
    allow(Open3).to receive(:capture3).and_return([ stdout, "parser diagnostic", status ])
  end

  # @spec KNOWLEDGE-014
  it "fails a host parser exit instead of accepting an empty shard" do
    tool_result(exit_code: 137)

    expect { parse }.to raise_error(RuntimeError, "ast-grep failed with exit 137")
  end

  # @spec KNOWLEDGE-014
  it "accepts the host no-matches exit as an empty shard" do
    tool_result(exit_code: 1)

    expect(parse).to eq([])
  end

  # @spec KNOWLEDGE-014
  it "fails empty successful parser output" do
    tool_result

    expect { parse }.to raise_error(JSON::ParserError)
  end

  # @spec KNOWLEDGE-014
  it "fails malformed parser output" do
    tool_result(stdout: "truncated-output")

    expect { parse }.to raise_error(JSON::ParserError)
  end

  # @spec KNOWLEDGE-014
  it "fails a paged collector when the parser executable is missing" do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

    expect { parse }.to raise_error(Errno::ENOENT)
  end

  # @spec KNOWLEDGE-001
  it "preserves the legacy full-call best-effort behavior" do
    collector.options.delete(:partial_collection)
    tool_result(exit_code: 137)

    expect(parse).to eq([])
  end
end
