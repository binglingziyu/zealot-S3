# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'openssl'

module ZealotDirect
  class Error < StandardError; end

  class Slice
    def initialize(file, remaining)
      @file, @remaining = file, remaining
    end

    def read(length = nil, buffer = nil)
      return nil if @remaining <= 0
      value = @file.read([length || @remaining, @remaining].min, buffer)
      @remaining -= value.bytesize if value
      value
    end
  end

  class Client
    def initialize(endpoint:, token:, verify_ssl: true, request_timeout: 600, wait_timeout: 1800, progress: nil, concurrency: 3)
      @endpoint = URI(endpoint.sub(%r{/+\z}, ''))
      raise Error, 'Endpoint must be an HTTP(S) origin' unless %w[http https].include?(@endpoint.scheme) && @endpoint.host && ['', '/'].include?(@endpoint.path) && !@endpoint.query && !@endpoint.userinfo
      @concurrency = Integer(concurrency)
      raise Error, 'Concurrency must be between 1 and 8' unless @concurrency.between?(1, 8)
      @progress_lock = Mutex.new
      @token, @verify_ssl, @timeout, @wait_timeout, @progress = token, verify_ssl, request_timeout, wait_timeout, progress
    end

    def upload(file:, channel_key:, kind: 'package', idempotency_key: nil, **metadata)
      path = File.expand_path(file)
      raise Error, 'File does not exist or is empty' unless File.file?(path) && File.size(path).positive?
      sha256 = Digest::SHA256.file(path).hexdigest
      idempotency_key ||= Digest::SHA256.hexdigest([channel_key, kind, File.basename(path), sha256].join(':'))
      session = api(:post, '/api/upload_sessions', metadata.merge(filename: File.basename(path), byte_size: File.size(path),
        sha256: sha256, channel_key: channel_key, kind: kind, idempotency_key: idempotency_key))
      id = session.fetch('id')
      raise Error, "Upload is #{session['state']}; choose a new idempotency key to restart" if %w[cancelled expired].include?(session['state'])
      if %w[initiated uploading].include?(session['state'])
        part_size = session.fetch('part_size')
        total = (File.size(path).to_f / part_size).ceil
        remote = api(:get, "/api/upload_sessions/#{id}/parts")
        uploaded = remote.fetch('parts').to_h { |part| [part.fetch('part_number'), part.fetch('byte_size')] }
        pending = %w[initiated uploading].include?(remote.fetch('state')) ? (1..total).to_a : []
        pending.reject! do |number|
          uploaded[number] == [part_size, File.size(path) - (number - 1) * part_size].min
        end
        pending.each_slice(@concurrency) do |batch|
          results = batch.map do |number|
            Thread.new do
              begin
                upload_with_retry(id, number, total, path, part_size)
                nil
              rescue StandardError => error
                error
              end
            end
          end.map(&:value)
          failure = results.compact.first
          raise failure if failure
        end
        session = api(:post, "/api/upload_sessions/#{id}/complete")
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @wait_timeout
      loop do
        return session if session['state'] == 'ready'
        raise Error, "Analysis failed: #{session['error']} (session #{id})" if %w[failed expired cancelled].include?(session['state'])
        raise Error, "Analysis still running; retry with the same idempotency key (session #{id})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
        session = api(:get, "/api/upload_sessions/#{id}")
      end
    end

    private

    def upload_with_retry(id, number, total, path, part_size)
      attempts = 0
      begin
        part = api(:post, "/api/upload_sessions/#{id}/parts", part_numbers: [number]).fetch('parts').first
        upload_part(part, path, (number - 1) * part_size)
      rescue Error, IOError, SystemCallError, Timeout::Error => error
        attempts += 1
        raise error if attempts >= 3
        sleep(attempts)
        retry
      end
      @progress_lock.synchronize { @progress.call(number, total) } if @progress
    end

    def api(method, path, values = {})
      uri = @endpoint.dup
      uri.path = path
      request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Accept'] = 'application/json'
      unless method == :get
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(values)
      end
      response = send_request(uri, request, verify_ssl: @verify_ssl)
      value = JSON.parse(response.body)
      raise Error, "Zealot HTTP #{response.code}: #{value['error']}" unless response.is_a?(Net::HTTPSuccess)
      value
    rescue JSON::ParserError
      raise Error, "Zealot returned a non-JSON response (HTTP #{response.code})"
    end

    def upload_part(part, path, offset)
      uri = URI(part.fetch('url'))
      raise Error, 'Invalid storage URL' unless %w[https http].include?(uri.scheme) && uri.host && !uri.userinfo
      File.open(path, 'rb') do |file|
        file.seek(offset)
        request = Net::HTTP::Put.new(uri)
        request.content_length = part.fetch('byte_size')
        request.body_stream = Slice.new(file, part.fetch('byte_size'))
        # Never send the Zealot bearer token to object storage. Cloud TLS stays verified.
        response = send_request(uri, request, verify_ssl: true)
        raise Error, "Storage upload failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
      end
    end

    def send_request(uri, request, verify_ssl:)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
        verify_mode: verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 30, read_timeout: @timeout, write_timeout: @timeout) { |http| http.request(request) }
    end
  end
end
