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

      prune_tag(entry, backend)
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
  #
  # Gated on ComboImageBuilder.buildable? — the same predicate that decides
  # which tags #prune_backend enumerates — so the referenced set and the
  # candidate set always speak about the same population of tags.
  def referenced_combo_tags
    TenantContext.with_system_access do
      Project.active.find_each.filter_map do |project|
        resolver = Containers::ImageResolver.new(project)
        image = resolver.resolve
        next if resolver.unsupported_languages.any?

        Containers::ComboImageBuilder.buildable?(image) ? image : nil
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

  def prune_tag(entry, backend)
    tag = entry.fetch(:image)
    built_at = pruneable_built_at(tag, backend, listed_labels: entry.fetch(:labels, {}))
    return unless built_at

    backend.delete_image(tag, force: true)
    Rails.logger.info(
      message: "agent_combo_image_cleanup.tag_pruned",
      image: tag,
      backend: backend.identifier,
      built_at: built_at.iso8601
    )
  end

  def pruneable_built_at(tag, backend, listed_labels:)
    label_sets = label_sets_for_prune(tag, backend, listed_labels)
    built_ats = label_sets.filter_map { |labels| parse_built_at(labels) }
    return if built_ats.size != label_sets.size

    newest_copy = built_ats.max
    newest_copy if newest_copy < RETENTION.ago
  end

  def label_sets_for_prune(tag, backend, listed_labels)
    backend.image_label_sets(tag)
  rescue Docker::Error::NotFoundError => e
    Rails.logger.warn(
      message: "agent_combo_image_cleanup.partial_tag_visibility",
      image: tag,
      backend: backend.identifier,
      error: e.message
    )
    [ listed_labels ]
  end

  def parse_built_at(labels)
    Time.zone.parse(labels[Containers::ComboImageBuilder::BUILT_AT_LABEL].to_s)
  end
end
