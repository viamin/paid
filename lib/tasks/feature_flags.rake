# frozen_string_literal: true

module FeatureFlagTasks
  module_function

  def project_scope
    project_reference = ENV["PROJECT"].to_s.strip
    project_id = ENV["PROJECT_ID"].to_s.strip

    raise ArgumentError, "Use PROJECT_ID=<id> for project-scoped feature flag changes" if project_reference.present?
    return nil if project_id.empty?

    project_id = Integer(project_id, 10)
    Project.find(project_id)
  rescue ArgumentError => e
    raise e if e.message == "Use PROJECT_ID=<id> for project-scoped feature flag changes"

    raise ArgumentError, "PROJECT_ID must be an integer"
  rescue ActiveRecord::RecordNotFound
    raise ArgumentError, "PROJECT_ID=#{project_id} does not match an existing project"
  end

  def scope_label(project)
    project ? "project #{project.full_name}" : "global"
  end

  def print_status(flag_name, project: nil)
    definition = FeatureFlags.definition(flag_name)
    enabled = FeatureFlags.enabled?(definition.name, project:)
    rollout = FeatureFlags.rollout_status(definition.name)

    puts "#{definition.name}: #{enabled ? 'enabled' : 'disabled'} (#{scope_label(project)})"
    puts "  owner: #{definition.owner}"
    puts "  intent: #{definition.intent}"
    puts "  rollout_plan: #{definition.rollout_plan}"
    puts "  cleanup_criteria: #{definition.cleanup_criteria}"
    puts "  boolean: #{rollout[:boolean]}"
    puts "  percentage_of_actors: #{rollout[:percentage_of_actors]}"
    puts "  percentage_of_time: #{rollout[:percentage_of_time]}"
    puts "  actors: #{rollout[:actors].presence || 'none'}"
    puts "  groups: #{rollout[:groups].presence || 'none'}"
  end
end

namespace :feature_flags do
  desc "List supported feature flags and their current state"
  task list: :environment do
    project = FeatureFlagTasks.project_scope

    FeatureFlags.definitions.each do |definition|
      FeatureFlagTasks.print_status(definition.name, project:)
    end
  end

  desc "Enable a feature flag globally or for PROJECT_ID=<id>"
  task :enable, [ :flag ] => :environment do |_task, args|
    project = FeatureFlagTasks.project_scope
    FeatureFlags.enable!(args.fetch(:flag), project:)

    puts "Enabled #{args.fetch(:flag)} for #{FeatureFlagTasks.scope_label(project)}"
  end

  desc "Disable a feature flag globally or for PROJECT_ID=<id>"
  task :disable, [ :flag ] => :environment do |_task, args|
    project = FeatureFlagTasks.project_scope
    FeatureFlags.disable!(args.fetch(:flag), project:)

    puts "Disabled #{args.fetch(:flag)} for #{FeatureFlagTasks.scope_label(project)}"
  end

  desc "Enable a percentage-of-actors rollout globally"
  task :enable_percentage_of_actors, [ :flag, :percentage ] => :environment do |_task, args|
    FeatureFlags.enable_percentage_of_actors(args.fetch(:flag), args.fetch(:percentage))

    puts "Enabled #{args.fetch(:flag)} for #{args.fetch(:percentage)}% of actors"
  end

  desc "Enable a percentage-of-time rollout globally"
  task :enable_percentage_of_time, [ :flag, :percentage ] => :environment do |_task, args|
    FeatureFlags.enable_percentage_of_time(args.fetch(:flag), args.fetch(:percentage))

    puts "Enabled #{args.fetch(:flag)} for #{args.fetch(:percentage)}% of time"
  end

  desc "Show full rollout status for a feature flag"
  task :status, [ :flag ] => :environment do |_task, args|
    FeatureFlagTasks.print_status(args.fetch(:flag), project: FeatureFlagTasks.project_scope)
  end
end
