# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127194149_validate_project_delegation_postures_level_constraint")

RSpec.describe ValidateProjectDelegationPosturesLevelConstraint do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }
  let(:name) { "chk_project_delegation_postures_level" }

  def reference
    connection.check_constraints(:project_delegation_postures).find { |check| check.name == name }
  end

  around do |example|
    original = reference
    connection.remove_check_constraint :project_delegation_postures, name: name
    connection.add_check_constraint :project_delegation_postures, original.expression, name: name, validate: false
    connection.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    connection.validate_check_constraint :project_delegation_postures, name: name if original&.validated?
  end

  # @spec POSTGRESQL-PERSISTENCE-021
  it "validates existing rows without changing the predicate or data" do
    original = reference.to_h
    count = connection.select_value("SELECT COUNT(*) FROM project_delegation_postures")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(reference).to be_validated
    expect(reference.to_h).to eq(original.merge(options: original.fetch(:options).merge(validate: true)))
    expect(connection.select_value("SELECT COUNT(*) FROM project_delegation_postures")).to eq(count)
  end

  # @spec POSTGRESQL-PERSISTENCE-021
  it "preserves validation on rollback" do
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:up)
      migration.migrate(:down)
    end
    expect(reference).to be_validated
  end
end
