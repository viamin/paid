# frozen_string_literal: true

# Prunes stale paid-agent combo images (RDR-046 / #3613).
#
# A combo tag is pruned when it is currently unreferenced (no project resolves
# to it, no running container uses it) and its recorded build timestamp is
# older than the retention window (30 days). The built-at label is the closest
# available proxy for "unreferenced since": reference-drop events are not
# tracked, so the job may retain a recently-unreferenced image until its label
# ages past the window (over-retention) — it never prunes an image younger
# than the window.
#
# The base image is never pruned, and images built by hand (no builder labels)
# are left alone — this job only reaps what ComboImageBuilder produced.
# Scheduled via GoodJob cron.
class AgentComboImageCleanupJob < ApplicationJob
  queue_as :maintenance

  RETENTION = 30.days

  def perform
    referenced = referenced_combo_tags
    Containers.all_backends.each do |backend|
      prune_backend(backend, referenced: referenced)
    rescue => e
      Rails.logger.error(
        message: "agent_combo_image_cleanup.backend_failed",
        backend: backend.identifier,
        error: e.message
      )
    end
  end

  private

  def prune_backend(backend, referenced:)
    Containers::ComboImageBuilder.combo_images(backend: backend).each do |entry|
      next if referenced.include?(entry[:image])
      next if tag_in_use?(entry[:image], backend)

      built_at = parse_built_at(entry[:labels])
      if built_at && built_at < RETENTION.ago
        backend.delete_image(entry[:image], force: true)
        Rails.logger.info(
          message: "agent_combo_image_cleanup.tag_pruned",
          image: entry[:image],
          backend: backend.identifier,
          built_at: built_at.iso8601
        )
      end
    end
  end

  # Every combo tag any project still resolves to. Resolving is cheap (pure
  # token math over persisted profiles), so the sweep stays read-only until a
  # prune decision is made.
  #
  # Projects with any unsupported runtime (e.g. kotlin + go) are excluded even
  # though non-strict resolution would still compute a combo tag for the
  # supported subset (paid-agent:go) — Containers::Provision resolves in
  # strict mode and rejects those projects outright, so that tag is never
  # actually reachable and must not be kept alive on its account.
  def referenced_combo_tags
    TenantContext.with_system_access do
      Project.find_each.filter_map do |project|
        resolver = Containers::ImageResolver.new(project)
        image = resolver.resolve
        next if resolver.unsupported_languages.any?

        Containers::ImageResolver.combo?(image) ? image : nil
      end
    end.to_set
  end

  def tag_in_use?(tag, backend)
    backend.image_in_use?(tag)
  rescue Docker::Error::DockerError => e
    Rails.logger.warn(
      message: "agent_combo_image_cleanup.usage_check_failed",
      image: tag,
      error: e.message
    )
    true
  end

  def parse_built_at(labels)
    Time.zone.parse(labels[Containers::ComboImageBuilder::BUILT_AT_LABEL].to_s)
  end
end
