# Run delete on the first isolated restored DB, then restore the original cloud
# archive into a second DB and run verify. Never changes the live test source DB.
require 'json'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')
phase = ENV.fetch('OLD_POINT_PHASE')
database = ActiveRecord::Base.connection_db_config.database
expected_database = phase == 'delete' ? 'zealot_restore_20260907_a' : 'zealot_restore_20260907_b'
raise 'Unexpected rehearsal database' unless database == expected_database
proof_path = '/tmp/zealot-old-point-proof.json'

def downloaded_sha(object)
  sha = Digest::SHA256.new
  object.storage_profile.client.get_object(bucket: object.storage_profile.bucket, key: object.key) { |chunk| sha.update(chunk) }
  sha.hexdigest
end

case phase
when 'delete'
  raise 'Deletion phase must exercise normal lifecycle' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
  release = Release.where.not(package_object_id: nil, icon_object_id: nil).first!
  debug = DebugFile.where.not(stored_object_id: nil).first!
  objects = [release.package_object, release.icon_object, debug.stored_object]
  proof = { release_id: release.id, debug_file_id: debug.id, objects: objects.map { |o| { id: o.id, kind: o.kind, sha256: downloaded_sha(o) } } }
  release.destroy!
  debug.destroy!
  objects.each do |object|
    object.reload
    raise 'Deletion did not retain cloud object' unless object.state_deleted? && object.purge_after > 36.days.from_now
  end
  raise 'Unexpected unrelated due deletions in rehearsal DB' if StoredObject.where(state: 'deleted').where('purge_after < ?', Time.current).exists?
  PurgeStoredObjectsJob.perform_now
  objects.each do |object|
    expected = proof[:objects].find { |entry| entry[:id] == object.id }
    raise 'Garbage collection damaged retained object' unless downloaded_sha(object) == expected[:sha256]
  end
  File.write(proof_path, JSON.generate(proof))
  puts JSON.generate(deleted_release: release.id, deleted_debug: debug.id, retained_objects: objects.size, retention_days_minimum: 36)
when 'verify'
  raise 'Recovery mode required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
  proof = JSON.parse(File.read(proof_path))
  release = Release.find(proof.fetch('release_id'))
  debug = DebugFile.find(proof.fetch('debug_file_id'))
  ids = [release.package_object_id, release.icon_object_id, debug.stored_object_id]
  raise 'Old object bindings changed' unless ids.sort == proof.fetch('objects').map { |entry| entry.fetch('id') }.sort
  proof.fetch('objects').each do |entry|
    object = StoredObject.find(entry.fetch('id'))
    raise 'Old archive did not restore ready state' unless object.state_ready?
    raise 'Restored object bytes changed' unless downloaded_sha(object) == entry.fetch('sha256')
  end
  raise 'Recovery unexpectedly enabled cron' if Rails.application.config.good_job.enable_cron
  puts JSON.generate(old_release_restored: true, old_debug_restored: true, objects_downloaded_with_matching_sha256: ids.size, recovery_cron_disabled: true)
else
  raise 'Phase must be delete or verify'
end
