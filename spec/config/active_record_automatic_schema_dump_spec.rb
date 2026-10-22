# frozen_string_literal: true

require "spec_helper"
require "open3"
require "active_record"

RSpec.describe ActiveRecord do
  # @spec POSTGRESQL-PERSISTENCE-011
  it "disables automatic dumping only for update commands that opt out" do
    initializer = File.expand_path("../../config/initializers/automatic_schema_dump.rb", __dir__)
    [ nil, "0", "1" ].each do |setting|
      stdout, stderr, status = Open3.capture3(
        { "PAID_SKIP_AUTO_SCHEMA_DUMP" => setting },
        "bundle", "exec", "ruby", "-ractive_record", "-e",
        "load ARGV.fetch(0); puts ActiveRecord.dump_schema_after_migration", initializer
      )

      expect(status.success?).to be(true), stderr
      expect(stdout.strip).to eq(setting == "1" ? "false" : "true")
    end
  end
end
