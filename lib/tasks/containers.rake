# frozen_string_literal: true

namespace :containers do
  desc "Rebuild all paid-agent combo images (present or project-resolved) against the current base image (RDR-046 cascade)"
  task rebuild_combo_images: :environment do
    builder = Containers::ComboImageBuilder
    backends = Containers.all_backends
    present = backends.flat_map { |backend| builder.combo_images(backend: backend).map { |entry| [ backend, entry[:image] ] } }
    resolved = Project.find_each.filter_map do |project|
      image = Containers::ImageResolver.resolve(project)
      Containers::ImageResolver.combo?(image) ? image : nil
    end.uniq

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
