# frozen_string_literal: true
require_relative 'foundation'

class PublicDownloadTest < FoundationTest
  def test_public_download_origin_does_not_change_s3_signing
    p = profile
    p.update!(force_path_style: true, public_download_origin: 'https://downloads.example.com/')
    p.credentials = { access_key_id: 'test-access', secret_access_key: 'test-secret' }
    p.save!
    a = app
    object = StoredObject.create!(storage_profile: p, app: a, kind: 'package', state: 'ready',
      key: 'zealot/objects/a b+中文.apk', filename: 'demo.apk')
    expected = 'https://downloads.example.com/zealot/objects/a%20b%2B%E4%B8%AD%E6%96%87.apk'
    assert_equal expected, object.signed_url
    assert_equal expected, Zealot::Storage::S3::File.new(object.key, stored_object: object).url
    signed = Aws::S3::Presigner.new(client: p.client(download: true)).presigned_url(:upload_part,
      bucket: p.bucket, key: object.key, upload_id: 'upload', part_number: 1)
    assert_equal 'example.r2.cloudflarestorage.com', URI(signed).host
    assert_includes URI(signed).query, 'X-Amz-Signature'
    assert p.public_bucket?
    backup = Backup.new(storage_profile: p)
    assert_raises(ArgumentError) { Backups::RemoteDatabase.new(backup) }
    alias_profile = profile
    assert alias_profile.public_bucket?
    assert_raises(ArgumentError) { Backups::RemoteDatabase.new(Backup.new(storage_profile: alias_profile)) }
    alias_profile.update!(bucket: 'separate-private-backups')
    refute alias_profile.public_bucket?
    assert Backups::RemoteDatabase.new(Backup.new(storage_profile: alias_profile))
    refute p.update(public_download_origin: 'https://elsewhere.example.com')
  end
end
