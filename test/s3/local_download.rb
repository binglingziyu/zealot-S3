require 'minitest/autorun'
require 'minitest/mock'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class LocalDownloadTest < Minitest::Test
  def setup
    @maximum = ENV['ZEALOT_PARSER_MAX_FILE_BYTES']
    @pattern = Rails.root.join("tmp/zealot-object-*-#{Process.pid}-*").to_s
    @paths = Dir[@pattern]
    @client = Zealot::Storage::S3.client
    @bucket = ENV.fetch('ZEALOT_S3_BUCKET')
    @key = "local-download-test/#{SecureRandom.uuid}.bin"
  end

  def teardown
    @maximum.nil? ? ENV.delete('ZEALOT_PARSER_MAX_FILE_BYTES') : ENV['ZEALOT_PARSER_MAX_FILE_BYTES'] = @maximum
    @client.delete_object(bucket: @bucket, key: @key)
    assert_empty Dir[@pattern] - @paths
  end

  def download(client: @client, expected_size: nil, &block)
    Storage::LocalDownload.open(client: client, bucket: @bucket, key: @key,
      filename: 'package.bin', expected_size: expected_size, &block)
  end

  def test_real_binary_download_and_exception_cleanup
    bytes = Random.new(632).bytes(2 * 1024**2)
    @client.put_object(bucket: @bucket, key: @key, body: bytes)
    path = nil
    download(expected_size: bytes.bytesize) do |local|
      path = local
      assert_equal Digest::SHA256.hexdigest(bytes), Digest::SHA256.file(local).hexdigest
    end
    refute File.exist?(path)
    assert_raises(RuntimeError) do
      download(expected_size: bytes.bytesize) { |local| path = local; raise 'Parser failed' }
    end
    refute File.exist?(path)
  end

  def test_real_oversized_object_is_rejected_before_parsing
    @client.put_object(bucket: @bucket, key: @key, body: 'a' * 100_000)
    assert_raises(Storage::LocalDownload::LimitExceeded) do
      download(expected_size: 10) { flunk 'Oversized data reached parser' }
    end
  end

  def test_real_truncated_object_is_rejected_before_parsing
    @client.put_object(bucket: @bucket, key: @key, body: 'short')
    assert_raises(Storage::LocalDownload::SizeMismatch) do
      download(expected_size: 10) { flunk 'Incomplete data reached parser' }
    end
  end

  def test_unknown_size_uses_configured_limit_and_stops_consuming_chunks
    ENV['ZEALOT_PARSER_MAX_FILE_BYTES'] = '4'
    client = Object.new
    client.define_singleton_method(:get_object) do |**_args, &write|
      write.call('abc')
      write.call('def')
      raise 'Downloaded past the limit'
    end
    assert_raises(Storage::LocalDownload::LimitExceeded) do
      download(client: client) { flunk 'Oversized data reached parser' }
    end
  end

  def test_rejects_known_size_above_limit_without_requesting_storage
    ENV['ZEALOT_PARSER_MAX_FILE_BYTES'] = '4'
    client = Object.new # Any accidental network method raises NoMethodError.
    assert_raises(Storage::LocalDownload::LimitExceeded) do
      download(client: client, expected_size: 5) { flunk 'Oversized data reached parser' }
    end
  end

  def test_metadata_parser_failure_still_cleans_extracted_files
    cleared = false
    parser = Object.new
    parser.define_singleton_method(:format) { AppInfo::Format::APK }
    parser.define_singleton_method(:platform) { raise 'Broken archive metadata' }
    parser.define_singleton_method(:clear!) { cleared = true }
    Tempfile.create('parser-cleanup-test') do |file|
      file.write(SecureRandom.hex(32))
      file.flush
      AppInfo.stub(:parse, parser) do
        error = assert_raises(RuntimeError) { TeardownService.new(file.path).send(:process) }
        assert_equal 'Broken archive metadata', error.message
      end
    end
    assert cleared, 'Parser scratch files must be removed even when metadata extraction raises'
  end
end
