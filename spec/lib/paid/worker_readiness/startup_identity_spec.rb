# frozen_string_literal: true

require "rails_helper"
require "paid/worker_readiness/startup_identity"
require "open3"
require "rbconfig"
require "tmpdir"

# @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-004
RSpec.describe Paid::WorkerReadiness::StartupIdentity do
  it "retains the identity captured before application loading" do
    identity = described_class.capture { "development:head:fingerprint" }

    expect(identity.revision).to eq("development:head:fingerprint")
    expect(identity.verify!).to eq(identity)
  end

  it "refuses a startup whose source identity changes while application code loads" do
    revisions = [ "development:head:before", "development:head:after" ]
    identity = described_class.capture { revisions.shift }

    expect { identity.verify! }
      .to raise_error(Paid::WorkerReadiness::StartupIdentity::SourceChangedError,
        /source changed while the Temporal worker was booting/)
  end

  it "detects a real same-HEAD development source edit across the startup boundary" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root, exception: true)
      system("git", "-C", root, "config", "user.email", "test@example.test", exception: true)
      system("git", "-C", root, "config", "user.name", "Test", exception: true)
      source_path = File.join(root, "app.rb")
      File.write(source_path, "VALUE = :before\n")
      system("git", "-C", root, "add", "app.rb", exception: true)
      system("git", "-C", root, "commit", "-qm", "base", exception: true)
      identity = described_class.capture do
        TrustedMeasurements::DeploymentSignal.current(root:, environment: "development")
      end

      File.write(source_path, "VALUE = :after\n")

      expect { identity.verify! }.to raise_error(described_class::SourceChangedError)
    end
  end

  it "surrounds Rails boot and worker construction in the executable" do
    source = Rails.root.join("bin/temporal_worker").read
    capture = source.index("StartupIdentity.capture")
    rails_boot = source.index('require_relative "../config/environment"')
    verify = source.index("startup_identity.verify!")
    readiness = source.index("WorkerReadiness::Heartbeat.start")
    polling = source.index("Temporalio::Worker.run_all")

    expect(capture).to be < rails_boot
    expect(verify).to be > source.index("workers = case worker_mode")
    expect(verify).to be < readiness
    expect(verify).to be < polling
  end

  it "captures a development identity from the real executable before Rails boots" do
    status, output = run_until_rails_boot("RAILS_ENV" => "development", "PAID_DEPLOYED_REVISION" => nil)

    expect(status).to be_success
    expect(output).to include("reached Rails boot")
  end

  it "captures a production identity from the real executable before Rails boots" do
    status, output = run_until_rails_boot(
      "RAILS_ENV" => "production", "PAID_DEPLOYED_REVISION" => "release-123"
    )

    expect(status).to be_success
    expect(output).to include("reached Rails boot")
  end

  def run_until_rails_boot(environment)
    Dir.mktmpdir do |directory|
      prelude = File.join(directory, "stop_before_rails.rb")
      File.write(prelude, <<~RUBY)
        module Kernel
          def require_relative(path)
            if path == "../config/environment"
              puts "reached Rails boot"
              exit 0
            end

            location = caller_locations(1, 1).first.absolute_path
            require File.expand_path(path, File.dirname(location))
          end
        end
      RUBY
      command = [ RbConfig.ruby, "-r#{prelude}", Rails.root.join("bin/temporal_worker").to_s ]
      output, error, status = Open3.capture3(environment, *command, chdir: Rails.root.to_s)
      [ status, output + error ]
    end
  end
end
