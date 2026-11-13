# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe TrustedMeasurements::DeploymentSignal do # @spec TRUSTED-MEASUREMENTS-007
  around do |example|
    previous = ENV.delete("PAID_DEPLOYED_REVISION")
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  it "identifies a development checkout and invalidates the identity when tracked or untracked source changes" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root, exception: true)
      system("git", "-C", root, "config", "user.email", "test@example.test", exception: true)
      system("git", "-C", root, "config", "user.name", "Test", exception: true)
      File.write(File.join(root, "app.rb"), "puts :one\n")
      system("git", "-C", root, "add", "app.rb", exception: true)
      system("git", "-C", root, "commit", "-qm", "base", exception: true)

      clean = described_class.current(root:, environment: "development")
      ENV["PAID_DEPLOYED_REVISION"] = "stale-override"
      expect(described_class.current(root:, environment: "development")).to eq(clean)
      File.write(File.join(root, "app.rb"), "puts :two\n")
      tracked = described_class.current(root:, environment: "development")
      File.write(File.join(root, "new.rb"), "puts :new\n")
      untracked = described_class.current(root:, environment: "development")

      expect(clean).to start_with("development:")
      expect([ clean, tracked, untracked ].uniq.size).to eq(3)
    end
  end

  it "requires an explicit signal outside development" do
    expect(described_class.current(environment: "production")).to be_nil
    ENV["PAID_DEPLOYED_REVISION"] = "release-123"
    expect(described_class.current(environment: "production")).to eq("release-123")
  end

  it "returns unknown when a development checkout cannot be read" do
    Dir.mktmpdir do |root|
      previous_git_dir = ENV["GIT_DIR"]
      ENV["GIT_DIR"] = Rails.root.join(".git").to_s

      expect(described_class.current(root:, environment: "development")).to be_nil
    ensure
      ENV["GIT_DIR"] = previous_git_dir
    end
  end
end
