# Run with: bundle exec rails runner test/s3/r2_protocol.rb
# Uses configured S3 credentials; creates and removes only its own UUID test keys.
require 'net/http'
require 'json'
client = Zealot::Storage::S3.client
bucket = Zealot::Storage::S3.bucket
prefix = Zealot::Storage::S3.key("verification/#{SecureRandom.uuid}/")
key = "#{prefix}multipart.bin"
origin = ENV.fetch('R2_VERIFY_ORIGIN', 'https://zealot.dev.ihubin.com')
result = {}
upload_id = nil
begin
  upload_id = client.create_multipart_upload(bucket: bucket, key: key).upload_id
  uploads = client.list_multipart_uploads(bucket: bucket, prefix: prefix).uploads
  result[:prefix_lists_key] = uploads.any? { |u| u.key == key }
  result[:listed_upload_id_matches] = uploads.any? { |u| u.key == key && u.upload_id == upload_id }
  presigner = Aws::S3::Presigner.new(client: client)
  parts = []
  expected = Digest::SHA256.new
  old_url = nil
  [5 * 1024 * 1024, 12345].each_with_index do |size, index|
    body = (index.zero? ? 'a' : 'b') * size
    expected.update(body)
    url = presigner.presigned_url(:upload_part, bucket: bucket, key: key, upload_id: upload_id,
      part_number: index + 1, content_length: size, expires_in: 300)
    old_url ||= url
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
      if index.zero?
        preflight = Net::HTTP::Options.new(uri)
        preflight['Origin'] = origin
        preflight['Access-Control-Request-Method'] = 'PUT'
        preflight['Access-Control-Request-Headers'] = 'content-type'
        response = http.request(preflight)
        result[:cors] = { status: response.code.to_i, origin: response['access-control-allow-origin'],
          methods: response['access-control-allow-methods'], headers: response['access-control-allow-headers'] }
      end
      request = Net::HTTP::Put.new(uri)
      request['Origin'] = origin
      request['Content-Type'] = 'application/octet-stream'
      request.body = body
      response = http.request(request)
      raise "UploadPart HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      result[:expose_headers] = response['access-control-expose-headers']
      parts << { part_number: index + 1, etag: response['etag'] }
    end
  end
  result[:listed_parts] = client.list_parts(bucket: bucket, key: key, upload_id: upload_id).parts.size
  client.complete_multipart_upload(bucket: bucket, key: key, upload_id: upload_id, multipart_upload: { parts: parts })
  upload_id = nil
  result[:byte_size] = client.head_object(bucket: bucket, key: key).content_length
  digest = Digest::SHA256.new
  client.get_object(bucket: bucket, key: key) { |chunk| digest.update(chunk) }
  result[:sha256_matches] = digest.hexdigest == expected.hexdigest
  if ENV['R2_VERIFY_PUBLIC_ORIGIN']
    public_uri = URI("#{ENV.fetch('R2_VERIFY_PUBLIC_ORIGIN')}/#{key}")
    public_response = Net::HTTP.start(public_uri.host, public_uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(Net::HTTP::Head.new(public_uri))
    end
    result[:unsigned_public_status] = public_response.code.to_i
  end
  uri = URI(old_url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
    request = Net::HTTP::Put.new(uri)
    request.body = 'a' * (5 * 1024 * 1024)
    http.request(request)
  end
  result[:old_part_url_status] = response.code.to_i
  raise 'Completed object remains writable by old part URL' if response.is_a?(Net::HTTPSuccess)
  abort_key = "#{prefix}abort.bin"
  abort_id = client.create_multipart_upload(bucket: bucket, key: abort_key).upload_id
  client.abort_multipart_upload(bucket: bucket, key: abort_key, upload_id: abort_id)
  result[:abort_verified] = client.list_multipart_uploads(bucket: bucket, prefix: prefix).uploads.none? { |u| u.key == abort_key }
  raise 'Multipart validation failed' unless result[:sha256_matches] && result[:listed_parts] == 2 && result[:byte_size] == 5 * 1024 * 1024 + 12345
  puts JSON.generate(result)
ensure
  client.abort_multipart_upload(bucket: bucket, key: key, upload_id: upload_id) if upload_id
  client.delete_object(bucket: bucket, key: key)
end
