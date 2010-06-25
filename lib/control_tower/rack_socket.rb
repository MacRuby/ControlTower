# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

framework 'Foundation'
require 'CTParser'

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @server = server
      @socket = TCPServer.new(host, port)
      @status = :closed # Start closed and give the server time to start

      if concurrent
        @multithread = true
        @request_queue = Dispatch::Queue.concurrent
        puts "Caution! Wake turbulance from heavy aircraft landing on parallel runway.\n(Parallel Request Action ENABLED!)"
      else
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      end
      @request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      while (@status == :open)
        connection = @socket.accept
        $stdout.puts "**********\nReceived a socket connection at #{Time.now.to_f}"

        @request_queue.async(@request_group) do
          begin
            request_data = parse!(connection, prepare_environment)
            if request_data
              request_data['REMOTE_ADDR'] = connection.addr[3]
              $stdout.puts "Sending for handling by the server at #{Time.now.to_f}"
              response_data = @server.handle_request(request_data)
              $stdout.puts "Finished constructing reply at #{Time.now.to_f}"
              response_data.each do |chunk|
                connection.write chunk
              end
              $stdout.puts "Finished sending reply at #{Time.now.to_f}"
            end
          rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL, Errno::EBADF
            connection.close rescue nil
          rescue Errno::EMFILE
            # TODO: Need to do something about the dispatch queue...a group wait, maybe? or a dispatch semaphore?
          rescue Object => e
            $stdout.puts "Error receiving data: #{e.inspect}"
          ensure
            # TODO: Keep-Alive might be nice, but not yet
            connection.close rescue nil
          end
        end
      end
    end

    def close
      @status = :close

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        $stdout.puts "Timed out waiting for connections to close"
        exit 1
      end
      @request_group.wait
      @socket.close
    end


    private

    def prepare_environment
      { 'rack.errors' => $stderr,
        'rack.input' => NSMutableArray.alloc.init, # For now, collect the body as an array of NSData's
        'rack.multiprocess' => false,
        'rack.multithread' => @multithread,
        'rack.run_once' => false,
        'rack.version' => VERSION }
    end

    def parse!(connection, env)
      parser = ::CTParser.new
      data = NSMutableData.alloc.init
      parsing_headers = true # Parse headers first
      content_length = 0
      content_uploaded = 0
      connection_handle = NSFileHandle.alloc.initWithFileDescriptor(connection.fileno)

      $stdout.puts "Started parsing at #{Time.now.to_f}"
      while (parsing_headers || content_uploaded < content_length) do
        # Read the availableData on the socket and rescue any errors:
        incoming_bytes = connection_handle.availableData

        # Until the headers are done being parsed, we'll parse them
        if parsing_headers
          data.appendData(incoming_bytes)
          $stdout.puts "Recieved #{incoming_bytes.length} and have a total of #{data.length} bytes"
          nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
          if parser.finished
            $stdout.puts "Finished parsing headers at #{Time.now.to_f}"
            parsing_headers = false # We're done, now on to receiving the body
            content_uploaded = env['rack.input'].first.length
            content_length = env['CONTENT_LENGTH'].to_i
          end
        else # Done parsing headers, now just collect request body:
          content_uploaded += incoming_bytes.length
          env['rack.input'] << incoming_bytes
        end

        $stdout.puts "Finished receiving the body at #{Time.now.to_f}"
        # Rack says "Make that a StringIO!" TODO: We could be smarter about this
        body = Tempfile.new('control-tower-request-body-')
        body_handle = NSFileHandle.alloc.initWithFileDescriptor(body.fileno)
        env['rack.input'].each { |upload_data| body_handle.writeData(upload_data) }
        body.rewind
        env['rack.input'] = body
        $stdout.puts "Finished creating the rack.input file at #{Time.now.to_f}"
        # Returning what we've got...
        return env
      end
    end
  end
end
