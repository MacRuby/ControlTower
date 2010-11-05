#
# Copyright © 2010 Apple Inc. All rights reserved.
#
# IMPORTANT NOTE:  This file is licensed only for use on Apple-branded computers
# and is subject to the terms and conditions of the Apple Software License Agreement
# accompanying the package this file is a part of.  You may not port this file to
# another platform without Apple's written consent.
#

require 'rack/session/abstract/id'

module Rack
  module Session
    class GCDSession
      attr_reader :session_id

      def initialize(sid, store)
        @session_id = sid
        @session_store = store
        @session_values = {}
        @session_timer = nil
        @session_expires_at = nil
        @session_access_queue = Dispatch::Queue.new("session-#{sid}-access")

        # Sessions are self expiring. This is the block that handles expiry. The first task is to cancel the timer so that it only
        # fires once
        @timer_block = lambda do |src|
          @session_timer.cancel! unless @session_timer.nil?
          time_remaining = @session_expires_at - Time.now
          if time_remaining < 0
            @session_store.delete(@session_id)
          else
            @session_timer = Dispatch::Source.timer(time_remaining, 500, 0.5, @session_access_queue, &@timer_block)
          end
        end
      end

      def set_timer(seconds)
        # If this is the first time we're setting the timer, then we need to create the timer source as well
        @session_timer ||= Dispatch::Source.timer(seconds, 500, 0.5, @session_access_queue, &@timer_block)
        @session_access_queue.sync { @session_expires_at = Time.now + seconds }
      end

      def [](key)
        @session_values[key]
      end
      alias :fetch :[]

      def []=(key, value)
        @session_access_queue.sync do
          @session_values[key] = value
        end
        value
      end
      alias :store :[]=

      def delete(key)
        @session_access_queue.sync do
          @session_values.delete(key)
        end
      end

      def clear
        @session_access_queue.sync do
          @session_values.clear
        end
      end
    end

    class GCD < Abstract::ID
      def initialize(app, options={})
        super
        @sessions = {}
      end

      # Use UUIDs for session keys and save time on uniqueness checks
      def generate_sid
        uuid = CFUUIDCreate(nil)
        CFMakeCollectable(uuid)
        uuid_string = CFUUIDCreateString(nil, uuid)
        CFMakeCollectable(uuid_string)
        uuid_string
      end

      def get_session(env, sid)
        session = @sessions[sid] if sid
        unless sid and session
          env['rack.errors'].puts("Session '#{sid.inspect}' not found, initializing...") if $VERBOSE and not sid.nil?
          sid = generate_sid
          session = GCDSession.new(sid, @sessions)
          @sessions[sid] = session
        end
        return sid, session
      end

      def set_session(env, sid, session, options)
        session = @sessions[sid]
        if options[:renew] or options[:drop]
          @sessions.delete(sid)
          return false if options[:drop]
          session_id = generate_sid
          @sessions[session_id] = 0
        end
        session ||= GCDSession.new(generate_sid, @sessions)
        session.set_timer(options[:expire_after]) unless options[:expire_after].nil?
        session.session_id
      end
    end
  end
end
