# A local-only test bridge for Docker Desktop. Bind its published port to 127.0.0.1.
require 'socket'
server = TCPServer.new('0.0.0.0', Integer(ENV.fetch('LISTEN_PORT')))
loop do
  socket = server.accept
  Thread.new(socket) do |client|
    upstream = nil
    begin
      upstream = TCPSocket.new(ENV.fetch('TARGET_HOST'), Integer(ENV.fetch('TARGET_PORT')))
      [Thread.new { IO.copy_stream(client, upstream) rescue nil; upstream.close_write rescue nil },
       Thread.new { IO.copy_stream(upstream, client) rescue nil; client.close_write rescue nil }].each(&:join)
    rescue IOError, SystemCallError
      # Backend can be restarting while rebuilding assets.
    ensure
      client.close rescue nil
      upstream&.close rescue nil
    end
  end
end
