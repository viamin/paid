# frozen_string_literal: true

namespace :containers do
  desc "Rebuild all paid-agent combo images (present or project-resolved) against the current base image (RDR-046 cascade)"
  task rebuild_combo_images: :environment do
    builder = Containers::ComboImageBuilder
    backends = Containers.all_backends
    present = backends.flat_map { |backend| builder.combo_images(backend: backend).map { |entry| [ backend, entry[:image] ] } }
    # Projects with any unsupported runtime are excluded even though
    # non-strict resolution would still compute a combo tag for the
    # supported subset — Containers::Provision resolves in strict mode and
    # rejects those projects outright, so rebuilding that tag would waste a
    # build on an image no run can ever use.
    resolved = TenantContext.with_system_access do
      Project.find_each.filter_map do |project|
        resolver = Containers::ImageResolver.new(project)
        image = resolver.resolve
        next if resolver.unsupported_languages.any?

        Containers::ImageResolver.combo?(image) ? image : nil
      end.uniq
    end

    failures = false
    (present.uniq + backends.product(resolved)).uniq.each do |backend, image|
      builder.force_rebuild(image, backend: backend)
      puts "Rebuilt #{image} on #{backend.identifier}"
    rescue Containers::ComboImageBuilder::Error => e
      puts "FAILED #{image} on #{backend.identifier}: #{e.message}"
      failures = true
    end
    abort "One or more combo image rebuilds failed" if failures
  end
end
