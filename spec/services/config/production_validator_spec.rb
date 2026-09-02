# frozen_string_literal: true

require "rails_helper"

# Captures structured `warn` payloads so specs can assert on emitted warnings.
class LoggerRecorder
  attr_reader :warnings

  def initialize
    @warnings = []
  end

  def warn(payload)
    @warnings << payload
  end
end

# @spec PROD-CONFIG-001
RSpec.describe Config::ProductionValidator do
  # A plain recording logger so specs can assert on emitted warnings without
  # coupling to Rails.logger or RSpec mock limitations.
  let(:logger) { LoggerRecorder.new }
  let(:production_config_document) { Rails.root.join("docs/PRODUCTION_CONFIG.md").read }

  # Fully-valid production configuration; each spec overrides one field to test
  # a specific branch.
  let(:valid_kwargs) do
    {
      database_url: "postgres://paid:secret@db.internal:5432/paid_production",
      database_password: "secret",
      temporal_address: "temporal.internal:7233",
      redis_url: "redis://redis.internal:6379/0",
      qdrant_url: "http://qdrant.internal:6333",
      qdrant_api_key: "qdrant-secret",
      workspace_root: "/var/paid/workspaces",
      workspace_writable: true,
      container_backend: "remote",
      docker_socket_present: true,
      screenshots_configured: true,
      infrastructure_limit_errors: [],
      logger: logger
    }
  end

  def validator(**overrides)
    described_class.new(**valid_kwargs.merge(overrides))
  end

  describe "#validate!" do
    context "with all required settings present and non-localhost" do
      it "does not raise and emits no warnings" do
        expect { validator.validate! }.not_to raise_error
        expect(logger.warnings).to be_empty
      end
    end

    context "when a required setting is missing" do
      it "fails fast naming DATABASE_URL / PAID_DATABASE_PASSWORD when neither is set" do
        expect {
          validator(database_url: nil, database_password: nil).validate!
        }.to raise_error(
          described_class::ConfigurationError,
          /database: database connection \(set DATABASE_URL or PAID_DATABASE_PASSWORD\)/
        )
      end

      it "accepts DATABASE_URL even when PAID_DATABASE_PASSWORD is absent" do
        expect {
          validator(database_url: "postgres://paid:secret@db/paid", database_password: nil).validate!
        }.not_to raise_error
      end

      it "accepts PAID_DATABASE_PASSWORD even when DATABASE_URL is absent" do
        expect {
          validator(database_url: nil, database_password: "secret").validate!
        }.not_to raise_error
      end

      it "fails fast naming QDRANT_API_KEY when the key is blank" do
        expect {
          validator(qdrant_api_key: nil).validate!
        }.to raise_error(
          described_class::ConfigurationError,
          /qdrant_api_key: QDRANT_API_KEY/
        )
      end

      it "aggregates every missing setting into a single error message" do
        expect {
          validator(
            database_url: nil,
            database_password: nil,
            qdrant_api_key: ""
          ).validate!
        }.to raise_error(described_class::ConfigurationError) do |error|
          aggregate_failures "lists every problem at once" do
            expect(error.message).to include("database:")
            expect(error.message).to include("qdrant_api_key:")
            expect(error.message).to include("docs/PRODUCTION_CONFIG.md")
          end
        end
      end

      # @spec PROD-CONFIG-006
      it "fails fast when infrastructure safety limits are unset or unsafe" do
        expect {
          validator(infrastructure_limit_errors: [ "MAX_GLOBAL_REQUESTED_CPU_QUOTA must be set to a positive integer" ]).validate!
        }.to raise_error(
          described_class::ConfigurationError,
          /infrastructure_limits: MAX_GLOBAL_REQUESTED_CPU_QUOTA/
        )
      end
    end

    context "when development-unsafe defaults are detected" do
      it "warns (without failing) when Temporal resolves to localhost" do
        validator(temporal_address: "localhost:7233").validate!

        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Temporal address resolves to localhost/)
        )
      end

      it "warns when REDIS_URL is localhost" do
        validator(redis_url: "redis://localhost:6379/0").validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Redis URL resolves to localhost/)
        )
      end

      it "warns when REDIS_URL is unset (falls back to a localhost default)" do
        validator(redis_url: nil).validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Redis URL resolves to localhost/)
        )
      end

      it "warns when Qdrant URL is localhost" do
        validator(qdrant_url: "http://localhost:6333").validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Qdrant URL resolves to localhost/)
        )
      end

      it "warns when CONTAINER_BACKEND=local has no Docker socket" do
        validator(container_backend: "local", docker_socket_present: false).validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/CONTAINER_BACKEND=local but no Docker socket/)
        )
      end

      it "does not warn when CONTAINER_BACKEND=local has a Docker socket" do
        validator(container_backend: "local", docker_socket_present: true).validate!
        expect(logger.warnings.none? { |w| w[:detail]&.match?(/CONTAINER_BACKEND=local/) }).to be true
      end

      it "warns when the workspace root is not writable" do
        validator(workspace_writable: false).validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Workspace root is not writable/)
        )
      end

      it "warns when screenshots storage is not configured" do
        validator(screenshots_configured: false).validate!
        expect(logger.warnings).to include(
          message: "production_config.unsafe_default",
          detail: a_string_matching(/Screenshots storage is not configured/)
        )
      end

      it "still raises if a required setting is missing alongside the warning" do
        expect {
          validator(temporal_address: "localhost:7233", qdrant_api_key: nil).validate!
        }.to raise_error(described_class::ConfigurationError, /qdrant_api_key/)
      end
    end

    describe "localhost detection edge cases" do
      it "treats 127.0.0.1 and a bare host:port as localhost" do
        [ "127.0.0.1:7233", "localhost:7233", "redis://127.0.0.1:6379/0" ].each do |value|
          logger.warnings.clear
          validator(temporal_address: value, redis_url: value).validate!
          expect(logger.warnings).not_to be_empty
        end
      end

      it "does not treat a real internal host as localhost" do
        validator(
          temporal_address: "temporal.internal:7233",
          redis_url: "redis://redis.internal:6379/0",
          qdrant_url: "http://qdrant.internal:6333"
        ).validate!

        expect(logger.warnings.none? { |w| w[:detail]&.match?(/localhost/) }).to be true
      end
    end
  end

  describe ".build_command?" do
    around do |example|
      original_argv = ARGV.dup
      example.run
    ensure
      ARGV.replace(original_argv)
    end

    before do
      allow(described_class).to receive(:invoked_tasks).and_call_original
    end

    it "is true for the assets:precompile build task" do
      allow(described_class).to receive(:invoked_tasks).and_return([ "assets:precompile" ])
      expect(described_class.build_command?).to be true
    end

    it "is true for any assets:* task" do
      allow(described_class).to receive(:invoked_tasks).and_return([ "assets:clean" ])
      expect(described_class.build_command?).to be true
    end

    it "is false for runtime processes with no rake task (server / bin/jobs)" do
      allow(described_class).to receive(:invoked_tasks).and_return([])
      expect(described_class.build_command?).to be false
    end

    it "is false for deploy-time db tasks that carry secrets" do
      allow(described_class).to receive(:invoked_tasks).and_return([ "db:migrate" ])
      expect(described_class.build_command?).to be false
    end
  end

  describe ".documentation", :no_db do
    # @spec PROD-CONFIG-006
    it "documents every required production infrastructure safety limit" do
      missing_keys = Capacity::InfrastructureLimits::REQUIRED_PRODUCTION_KEYS.reject do |key|
        production_config_document.include?(key)
      end

      expect(missing_keys).to be_empty,
        "expected docs/PRODUCTION_CONFIG.md to document: #{missing_keys.join(', ')}"
    end
  end

  describe ".from_environment", :no_db do
    let(:writable_dir) { Dir.mktmpdir("workspace_root") }

    around do |example|
      previous_db_url = ENV["DATABASE_URL"]
      previous_db_pw = ENV["PAID_DATABASE_PASSWORD"]
      previous_qdrant_key = ENV["QDRANT_API_KEY"]
      ENV.delete("DATABASE_URL")
      ENV["PAID_DATABASE_PASSWORD"] = "db-secret"
      ENV["QDRANT_API_KEY"] = "qdrant-secret"
      example.run
    ensure
      ENV["DATABASE_URL"] = previous_db_url
      ENV["PAID_DATABASE_PASSWORD"] = previous_db_pw
      ENV["QDRANT_API_KEY"] = previous_qdrant_key
      FileUtils.remove_entry(writable_dir) if writable_dir && Dir.exist?(writable_dir)
    end

    before do
      allow(Paid).to receive_messages(
        temporal_address: "temporal.internal:7233",
        qdrant_url: "http://qdrant.internal:6333"
      )
      allow(Capacity::InfrastructureLimits).to receive(:production_errors).and_return([])
      allow(Rails.application.config.x).to receive(:workspace_root).and_return(writable_dir)
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return(nil)
      allow(ArtifactStorage).to receive(:configured?).and_return(true)
    end

    it "builds a passing validator from resolved environment values" do
      expect { described_class.from_environment.validate! }.not_to raise_error
    end

    it "raises when no database credential is available" do
      ENV.delete("PAID_DATABASE_PASSWORD")
      expect {
        described_class.from_environment.validate!
      }.to raise_error(described_class::ConfigurationError, /database:/)
    end
  end
end
