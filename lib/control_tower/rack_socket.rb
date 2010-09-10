# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

framework 'Foundation'
require 'CTParser'
require 'stringio'

CTParser # Making sure the Objective-C class is pre-loaded

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @app = server.app
      @socket = TCPServer.new(host, port)
      @socket.listen(50)
      @status = :closed # Start closed and give the server time to start

      if concurrent
        @multithread = true
        @request_queue = Dispatch::Queue.concurrent
        puts "Caution! Wake turbulance from heavy aircraft landing on parallel runway.\n(Parallel Request Action ENABLED!)"
      else
        @multithread = false
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      end
      @request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      while (@status == :open)
        connection = @socket.accept

        @request_queue.async(@request_group) do
          env = { 'rack.errors' => $stderr,
                  'rack.multiprocess' => false,
                  'rack.multithread' => @multithread,
                  'rack.run_once' => false,
                  'rack.version' => VERSION }
          resp = nil
          x_sendfile_header = 'X-Sendfile'
          x_sendfile = nil
          begin
            request_data = parse!(connection, env)
            if request_data
              request_data['REMOTE_ADDR'] = connection.addr[3]
              status, headers, body = @app.call(request_data)

              # If there's an X-Sendfile header, we'll use sendfile(2)
              if headers.has_key?(x_sendfile_header)
                x_sendfile = headers[x_sendfile_header]
                x_sendfile = ::File.open(x_sendfile, 'r') unless x_sendfile.kind_of? IO
                x_sendfile_size = x_sendfile.stat.size
                headers['Content-Length'] = x_sendfile_size
              end

              # Unless somebody's already set it for us (or we don't need it), set the Content-Length
              unless (status == -1 ||
                      (status >= 100 and status <= 199) ||
                      status == 204 ||
                      status == 304 ||
                      headers.has_key?('Content-Length'))
                headers['Content-Length'] = if body.respond_to?(:each)
                                              size = 0
                                              body.each { |x| size += x.bytesize }
                                              size
                                            else
                                              body.bytesize
                                            end
              end

              # TODO -- We don't handle keep-alive connections yet
              headers['Connection'] = 'close'

              resp = "HTTP/1.1 #{status}\r\n"
              headers.each do |header, value|
                resp << "#{header}: #{value}\r\n"
              end
              resp << "\r\n"

              # Start writing the response
              connection.write resp

              # Write the body
              if x_sendfile
                connection.sendfile(x_sendfile, 0, x_sendfile_size)
              elsif body.respond_to?(:each)
                body.each do |chunk|
                  connection.write chunk
                end
              else
                connection.write body
              end

            else
              $stderr.puts "Error: No request data received!"
            end
          rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL
            $stderr.puts "Error: Connection terminated!"
          rescue Object => e
            if resp.nil? && !connection.closed?
              connection.write "HTTP/1.1 400\r\n\r\n"
            else
              # We have a response, but there was trouble sending it:
              $stderr.puts "Error: Problem transmitting data -- #{e.inspect}"
              $stderr.puts e.backtrace.join("\n")
            end
          ensure
            # We should clean up after our tempfile, if we used one.
            input = env['rack.input']
            input.unlink if input.class == Tempfile
            connection.close rescue nil
          end
        end
      end
    end

    def close
      @status = :close

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        $stderr.puts "Timed out waiting for connections to close"
        exit 1
      end
      @request_group.wait
      @socket.close
    end


    private

    def parse!(connection, env)
      parser = Thread.current[:http_parser] ||= CTParser.new
      parser.reset
      data = NSMutableData.alloc.init
      data.increaseLengthBy(1) # add sentinel
      parsing_headers = true # Parse headers first
      nread = 0
      content_length = 0
      content_uploaded = 0
      connection_handle = NSFileHandle.alloc.initWithFileDescriptor(connection.fileno)

      while (parsing_headers || content_uploaded < content_length) do
        # Read the availableData on the socket and give up if there's nothing
        incoming_bytes = connection_handle.availableData
        return nil if incoming_bytes.length == 0

        # Until the headers are done being parsed, we'll parse them
        if parsing_headers
          data.setLength(data.length - 1) # Remove sentinel
          data.appendData(incoming_bytes)
          data.increaseLengthBy(1) # Add sentinel
          nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
          if parser.finished == 1
            parsing_headers = false # We're done, now on to receiving the body
            content_length = env['CONTENT_LENGTH'].to_i
            content_uploaded = env['rack.input'].length
          end
        else # Done parsing headers, now just collect request body:
          content_uploaded += incoming_bytes.length
          env['rack.input'].appendData(incoming_bytes)
        end
      end

      if content_length > 1024 * 1024
        body_file = Tempfile.new('control-tower-request-body-')
        NSFileHandle.alloc.initWithFileDescriptor(body_file.fileno).writeData(env['rack.input'])
        body_file.rewind
        env['rack.input'] = body_file
      else
        env['rack.input'] = StringIO.new(NSString.alloc.initWithData(env['rack.input'], encoding: NSASCIIStringEncoding))
      end
      # Returning what we've got...
      return env
    end
  end
end
