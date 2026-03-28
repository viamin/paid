# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "dev-update log cleanup in bin/setup" do # rubocop:disable RSpec/DescribeClass
  let(:max_log_bytes) { 524_288 }
  let(:keep_log_bytes) { 102_400 }
  let(:log_dir) { File.join(tmp_dir, "log", "dev-update") }
  let(:tmp_dir) { Dir.mktmpdir("log-cleanup-spec") }

  before { FileUtils.mkdir_p(log_dir) }

  after { FileUtils.rm_rf(tmp_dir) }

  def truncate_logs(dir)
    Dir[File.join(dir, "*.log")].each do |log_file|
      next unless File.size(log_file) > max_log_bytes

      tail = File.binread(log_file, keep_log_bytes, File.size(log_file) - keep_log_bytes)
      File.binwrite(log_file, tail)
    end
  end

  it "truncates oversized log files to the configured keep size" do
    log_path = File.join(log_dir, "dev-update.log")
    File.write(log_path, "A" * 600_000)

    truncate_logs(log_dir)

    expect(File.size(log_path)).to eq(keep_log_bytes)
    expect(File.read(log_path)).to eq("A" * keep_log_bytes)
  end

  it "preserves the tail of the file content" do
    content = ("0" * 500_000) + ("TAIL" * 25_000)
    log_path = File.join(log_dir, "dev-update.log")
    File.write(log_path, content)

    truncate_logs(log_dir)

    result = File.read(log_path)
    expect(result.size).to eq(keep_log_bytes)
    expect(result).to end_with("TAIL")
  end

  it "leaves small log files untouched" do
    small_content = "small log\n" * 100
    log_path = File.join(log_dir, "dev-update.log")
    File.write(log_path, small_content)

    truncate_logs(log_dir)

    expect(File.read(log_path)).to eq(small_content)
  end

  it "handles both dev-update.log and dev-start.log" do
    %w[dev-update.log dev-start.log].each do |name|
      File.write(File.join(log_dir, name), "X" * 600_000)
    end

    truncate_logs(log_dir)

    %w[dev-update.log dev-start.log].each do |name|
      expect(File.size(File.join(log_dir, name))).to eq(keep_log_bytes)
    end
  end

  it "is a no-op when log directory has no files" do
    expect { truncate_logs(log_dir) }.not_to raise_error
  end
end
