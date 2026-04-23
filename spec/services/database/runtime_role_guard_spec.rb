# frozen_string_literal: true

require "rails_helper"

RSpec.describe Database::RuntimeRoleGuard do
  let(:connection_config) { instance_double(ActiveRecord::DatabaseConfigurations::HashConfig, adapter: adapter) }
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, select_one: role) }
  let(:adapter) { "postgresql" }
  let(:role) { { "rolname" => "paid", "rolsuper" => false, "rolbypassrls" => false } }

  before do
    allow(ActiveRecord::Base).to receive_messages(connection_db_config: connection_config, connection: connection)
  end

  it "allows a PostgreSQL role without RLS bypass privileges" do
    expect { described_class.verify! }.not_to raise_error
  end

  it "rejects a superuser runtime role" do
    role["rolsuper"] = true

    expect { described_class.verify! }
      .to raise_error(RuntimeError, /Unsafe PostgreSQL runtime role "paid": SUPERUSER/)
  end

  it "rejects a runtime role with BYPASSRLS" do
    role["rolbypassrls"] = "t"

    expect { described_class.verify! }
      .to raise_error(RuntimeError, /Unsafe PostgreSQL runtime role "paid": BYPASSRLS/)
  end

  it "does not check non-PostgreSQL connections" do
    allow(connection_config).to receive(:adapter).and_return("sqlite3")

    described_class.verify!

    expect(connection).not_to have_received(:select_one)
  end

  it "can be explicitly disabled for one-off maintenance commands" do
    previous = ENV[described_class::SKIP_ENV]
    ENV[described_class::SKIP_ENV] = "true"

    begin
      described_class.verify!
    ensure
      ENV[described_class::SKIP_ENV] = previous
    end

    expect(connection).not_to have_received(:select_one)
  end

  it "skips Docker build-time boots that use the dummy secret key base" do
    previous = ENV["SECRET_KEY_BASE_DUMMY"]
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"

    begin
      described_class.verify!
    ensure
      ENV["SECRET_KEY_BASE_DUMMY"] = previous
    end

    expect(connection).not_to have_received(:select_one)
  end

  it "skips asset precompile tasks before opening a database connection" do
    rake = double(application: double(top_level_tasks: [ "assets:precompile" ]))
    stub_const("Rake", rake)

    described_class.verify!

    expect(connection).not_to have_received(:select_one)
  end
end
