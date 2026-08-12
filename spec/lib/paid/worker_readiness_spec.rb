# frozen_string_literal: true

require "rails_helper"
require "paid/worker_readiness"

RSpec.describe Paid::WorkerReadiness do
  let(:tmpdir) { Dir.mktmpdir }
  let(:file_path) { File.join(tmpdir, "worker-ready") }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  describe ".file_path" do
    it "returns the WORKER_READINESS_FILE env var when set" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect(described_class.file_path(env)).to eq(file_path)
    end

    it "falls back to a default path in the system tmpdir" do
      path = described_class.file_path({})
      expect(path).to eq(File.join(Dir.tmpdir, "paid-worker-ready"))
    end
  end

  describe ".mark_ready!" do
    it "creates the readiness file" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      expect(File.exist?(file_path)).to be true
    end

    it "writes JSON with pid and timestamp" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      payload = JSON.parse(File.read(file_path))
      expect(payload["pid"]).to eq(Process.pid)
      expect(payload["ready_at"]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it "creates parent directories if needed" do
      nested = File.join(tmpdir, "deep", "nested", "ready")
      described_class.mark_ready!("WORKER_READINESS_FILE" => nested)

      expect(File.exist?(nested)).to be true
    end

    it "does not raise when the file cannot be written" do
      env = { "WORKER_READINESS_FILE" => "/nonexistent-root/dir/ready" }
      expect { described_class.mark_ready!(env) }.not_to raise_error
    end
  end

  describe ".mark_not_ready!" do
    it "removes the readiness file" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)
      expect(File.exist?(file_path)).to be true

      described_class.mark_not_ready!(env)
      expect(File.exist?(file_path)).to be false
    end

    it "does not raise when the file does not exist" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect { described_class.mark_not_ready!(env) }.not_to raise_error
    end

    it "does not raise when the file cannot be deleted" do
      env = { "WORKER_READINESS_FILE" => "/nonexistent-root/dir/ready" }
      expect { described_class.mark_not_ready!(env) }.not_to raise_error
    end
  end

  describe ".ready?" do
    it "returns true after mark_ready!" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      expect(described_class.ready?(env)).to be true
    end

    it "returns false after mark_not_ready!" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)
      described_class.mark_not_ready!(env)

      expect(described_class.ready?(env)).to be false
    end

    it "returns false when no file exists" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect(described_class.ready?(env)).to be false
    end
  end
end
