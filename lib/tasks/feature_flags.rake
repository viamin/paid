# frozen_string_literal: true

module FeatureFlagTasks
  module_function

  def project_scope
    project_reference = ENV["PROJECT"].to_s.strip
    project_id = ENV["PROJECT_ID"].to_s.strip

    raise ArgumentError, "Use PROJECT_ID=<id> for project-scoped feature flag changes" if project_reference.present?
    return nil if project_id.empty?

    Project.find(Integer(project_id, 10))
  rescue ArgumentError => e
    raise e if e.message == "Use PROJECT_ID=<id> for project-scoped feature flag changes"

    raise ArgumentError, "PROJECT_ID must be an integer"
  end

  def scope_label(project)
    project ? "project #{project.full_name}" : "global"
  end
end

namespace :feature_flags do
  desc "List supported feature flags and their current state"
  task list: :environment do
    project = FeatureFlagTasks.project_scope

    FeatureFlags.definitions.each do |definition|
      enabled = FeatureFlags.enabled?(definition.name, project:)

      puts "#{definition.name}: #{enabled ? 'enabled' : 'disabled'} (#{FeatureFlagTasks.scope_label(project)})"
      puts "  owner: #{definition.owner}"
      puts "  intent: #{definition.intent}"
      puts "  rollout_plan: #{definition.rollout_plan}"
      puts "  cleanup_criteria: #{definition.cleanup_criteria}"
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
end
