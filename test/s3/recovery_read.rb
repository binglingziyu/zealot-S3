raise 'Disposable restored DB required' unless ENV.fetch('ZEALOT_POSTGRES_DB_NAME').start_with?('zealot_restore_')
raise 'Recovery mode required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
raise 'Scratch must start empty' if Dir[Rails.root.join('tmp/zealot-object-*').to_s].any?

result = Recovery::DatabaseVerifier.call
objects = StoredObject.where(id: Release.select(:package_object_id))
  .or(StoredObject.where(id: Release.select(:icon_object_id)))
  .or(StoredObject.where(id: DebugFile.select(:stored_object_id)))
counts = Hash.new(0)
hashes = 0
objects.find_each do |object|
  object.with_local_file do |path|
    raise 'Object bytes differ' if object.byte_size && File.size(path) != object.byte_size
    if object.sha256
      raise 'Object SHA256 differs' unless Digest::SHA256.file(path).hexdigest == object.sha256
      hashes += 1
    end
  end
  counts[object.kind] += 1
end
raise 'Missing restored artifact kinds' unless %w[package icon debug].all? { |kind| counts[kind].positive? }
raise 'Missing checksum evidence' unless hashes.positive?
raise 'Temporary download leaked' if Dir[Rails.root.join('tmp/zealot-object-*').to_s].any?
puts JSON.pretty_generate(result.merge(kinds: counts, sha256_verified: hashes, local_upload_volumes_used: false))
