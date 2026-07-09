# frozen_string_literal: true

namespace :knowledge do
  namespace :redact do
    desc "Run a physical redaction scrub against a project's already-indexed knowledge " \
         "and re-embed partially redacted chunks. " \
         "Usage: bin/rails 'knowledge:redact:scrub[PROJECT_ID]' " \
         "Options: ACTOR_ID=operator_user_id DRY_RUN=true SINCE=2026-01-01T00:00:00Z"
    task :scrub, [ :project_id ] => :environment do |_t, args|
      project_id = args[:project_id]
      abort "PROJECT_ID is required (e.g. bin/rails 'knowledge:redact:scrub[123]')" if project_id.blank?

      project = Project.find_by(id: project_id)
      abort "Project #{project_id} not found" unless project

      actor = build_actor
      dry_run = truthy?(ENV["DRY_RUN"])
      since = parse_since(ENV["SINCE"])
      skip_reembed = truthy?(ENV["SKIP_REEMBED"])

      scrubber = Knowledge::Redaction::Scrubber.new(
        project: project,
        qdrant_client: Paid.qdrant_client,
        actor: actor,
        dry_run: dry_run
      )
      scrub_result = scrubber.call
      print_scrub_summary(scrub_result, dry_run: dry_run)

      if !dry_run && !skip_reembed && scrub_result.scrubbed_chunks.positive?
        enqueue_reembed(project, actor: actor, since: since)
      end
    end

    desc "Re-embed partially redacted chunks for a project. " \
         "Usage: bin/rails 'knowledge:redact:reembed[PROJECT_ID]' " \
         "Options: ACTOR_ID=operator_user_id SINCE=2026-01-01T00:00:00Z CHUNK_IDS=uuid1,uuid2"
    task :reembed, [ :project_id ] => :environment do |_t, args|
      project_id = args[:project_id]
      abort "PROJECT_ID is required (e.g. bin/rails 'knowledge:redact:reembed[123]')" if project_id.blank?

      project = Project.find_by(id: project_id)
      abort "Project #{project_id} not found" unless project

      generator = build_reembed_generator(project)
      abort "No embedding provider configured for project #{project_id}" unless generator

      reembed = Knowledge::Redaction::Reembed.new(
        project: project,
        generator: generator,
        actor: build_actor,
        since: parse_since(ENV["SINCE"]),
        chunk_ids: parse_chunk_ids(ENV["CHUNK_IDS"])
      )
      result = reembed.call
      puts "Re-embedded #{result.reembedded_count} chunk(s), skipped #{result.skipped_count}, " \
           "duration #{result.duration_seconds}s"
    end
  end
end

def build_actor
  actor_id = ENV["ACTOR_ID"].presence
  actor_id ? { type: "operator", id: actor_id } : { type: "operator", id: "rake_task" }
end

def truthy?(value)
  %w[1 true yes on].include?(value.to_s.downcase)
end

def parse_since(raw)
  return nil if raw.blank?

  Time.parse(raw)
rescue ArgumentError
  abort "Invalid SINCE=#{raw.inspect}: must be an ISO8601 timestamp"
end

def parse_chunk_ids(raw)
  return nil if raw.blank?

  raw.split(",").map(&:strip).reject(&:empty?)
end

def print_scrub_summary(result, dry_run:)
  action = dry_run ? "Would scrub" : "Scrubbed"
  puts "#{action} #{result.scrubbed_chunks} chunk(s); " \
       "skipped #{result.skipped_chunks}; " \
       "deleted #{result.deleted_qdrant_points} Qdrant point(s); " \
       "collection_rebuilt=#{result.qdrant_collection_rebuilt}; " \
       "duration=#{result.duration_seconds}s"
end

def enqueue_reembed(project, actor:, since:)
  EmbedChunksJob.perform_later(project.id)
  puts "Queued EmbedChunksJob for project #{project.id} to re-embed partially redacted chunks"
rescue StandardError => e
  Rails.logger.warn(
    message: "knowledge.redaction.reembed_enqueue_failed",
    project_id: project.id,
    error_class: e.class.name,
    error: e.message
  )
  puts "WARN: failed to enqueue EmbedChunksJob: #{e.class}: #{e.message}"
end

def build_reembed_generator(project)
  configs = Knowledge::RunnerConfiguration.for_embedding_candidate_runners(project: project)
  return nil if configs.empty?

  Knowledge::Embeddings::ProxyGenerator.new(
    project: project,
    provider_configs: configs,
    containerize: true
  )
end
