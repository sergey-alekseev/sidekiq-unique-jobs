# frozen_string_literal: true

module SidekiqUniqueJobs
  class Locksmith # rubocop:disable ClassLength
    API_VERSION = '1'
    EXPIRES_IN = 10
    EXISTS_TOKEN = 1

    attr_reader :item, :unique_digest, :use_local_time, :resource_count
    attr_reader :lock_expiration, :lock_timeout, :stale_client_timeout

    # stale_client_timeout is the threshold of time before we assume
    # that something has gone terribly wrong with a client and we
    # invalidate it's lock.
    # Default is nil for which we don't check for stale clients
    # SidekiqUniqueJobs::Lock::WhileExecuting.new(item, :stale_client_timeout => 30, :redis => myRedis)
    # SidekiqUniqueJobs::Lock::WhileExecuting.new(item, :redis => myRedis)
    # SidekiqUniqueJobs::Lock::WhileExecuting.new(item, :resources => 1, :redis => myRedis)
    # SidekiqUniqueJobs::Lock::WhileExecuting.new(item, :host => "", :port => "")
    # SidekiqUniqueJobs::Lock::WhileExecuting.new(item, :path => "bla")
    def initialize(item, redis_pool = nil)
      @item                 = item
      @current_jid          = @item[JID_KEY]
      @unique_digest        = @item[UNIQUE_DIGEST_KEY]
      @redis_pool           = redis_pool
      @resource_count       = @item[SidekiqUniqueJobs::LOCK_RESOURCES_KEY] || 1
      @lock_expiration      = @item[SidekiqUniqueJobs::LOCK_EXPIRATION_KEY]
      @lock_timeout         = @item[SidekiqUniqueJobs::LOCK_TIMEOUT_KEY]
      @stale_client_timeout = @item[SidekiqUniqueJobs::STALE_CLIENT_TIMEOUT_KEY]
      @use_local_time       = @item[SidekiqUniqueJobs::USE_LOCAL_TIME_KEY]
      @tokens               = []
    end

    def create!
      SidekiqUniqueJobs::Scripts.call(
        :create_locks,
        @redis_pool,
        keys: [exists_key, grabbed_key, available_key, version_key],
        argv: [current_jid, lock_expiration, API_VERSION, resource_count],
      )
    end

    def exists?(conn = nil)
      if conn
        exists_in_redis?(conn)
      else
        SidekiqUniqueJobs.connection(@redis_pool) do |my_conn|
          exists?(my_conn)
        end
      end
    end

    def exists_in_redis?(conn)
      conn.exists(exists_key)
    end

    def available_count
      if exists?
        SidekiqUniqueJobs.connection(@redis_pool) do |conn|
          conn.llen(available_key) if exists?(conn)
        end
      else
        @resource_count
      end
    end

    def delete!
      SidekiqUniqueJobs::Scripts.call(
        :delete_locks,
        @redis_pool,
        keys: [exists_key, grabbed_key, available_key, version_key],
      )
    end

    def lock(timeout = nil) # rubocop:disable MethodLength
      create!
      release!

      SidekiqUniqueJobs.connection(@redis_pool) do |conn|
        if timeout.nil? || timeout.positive?
          # passing timeout 0 to blpop causes it to block
          _key, current_token = conn.blpop(available_key, timeout || 0)
        else
          current_token = conn.lpop(available_key)
        end

        return false if current_token.nil?

        @tokens.push(current_token)
        conn.hset(grabbed_key, current_token, current_time.to_f)
        return_value = current_token

        if block_given?
          begin
            return_value = yield current_token
          ensure
            signal(current_token)
          end
        end

        return_value
      end
    end
    alias wait lock

    def unlock
      return false unless locked?
      result = signal(@tokens.pop)
      result && result[1]
    end

    def locked?(token = nil)
      if token
        SidekiqUniqueJobs.connection(@redis_pool) do |conn|
          conn.hexists(grabbed_key, token)
        end
      else
        @tokens.each do |my_token|
          return true if locked?(my_token)
        end

        false
      end
    end

    def signal(token = nil)
      token ||= generate_unique_token

      SidekiqUniqueJobs::Scripts.call(
        :signal_locks,
        @redis_pool,
        keys: [exists_key, grabbed_key, available_key, version_key],
        argv: [token, lock_expiration],
      )
    end

    def all_tokens
      SidekiqUniqueJobs.connection(@redis_pool) do |conn|
        conn.multi do
          conn.lrange(available_key, 0, -1)
          conn.hkeys(grabbed_key)
        end.flatten
      end
    end

    def generate_unique_token
      tokens = all_tokens
      token = Random.rand.to_s

      token = Random.rand.to_s while tokens.include? token
    end

    def release!
      return unless check_staleness?

      if Gem::Version.new(SidekiqUniqueJobs.redis_version) >= Gem::Version.new('3.2')
        release_stale_locks_lua!
      else
        release_stale_locks_ruby!
      end
    end

    def available_key
      @available_key ||= namespaced_key('AVAILABLE')
    end

    def exists_key
      @exists_key ||= namespaced_key('EXISTS')
    end

    def grabbed_key
      @grabbed_key ||= namespaced_key('GRABBED')
    end

    def release_key
      @release_key ||= namespaced_key('RELEASE')
    end

    def version_key
      @version_key ||= namespaced_key('VERSION')
    end

    private

    def release_stale_locks_lua!
      SidekiqUniqueJobs::Scripts.call(
        :release_stale_locks,
        @redis_pool,
        keys:  [exists_key, grabbed_key, available_key, release_key],
        argv: [EXPIRES_IN, stale_client_timeout, lock_expiration],
      )
    end

    def release_stale_locks_ruby!
      SidekiqUniqueJobs.connection(@redis_pool) do |conn|
        simple_expiring_mutex(conn) do
          conn.hgetall(grabbed_key).each do |token, locked_at|
            timed_out_at = locked_at.to_f + stale_client_timeout

            signal(token) if timed_out_at < current_time.to_f
          end
        end
      end
    end

    def simple_expiring_mutex(conn) # rubocop:disable Metrics/MethodLength
      key_name = namespaced_key(key_name)
      cached_current_time = current_time.to_f
      my_lock_expires_at = cached_current_time + 10 + 1

      got_lock = conn.setnx(key_name, my_lock_expires_at)

      unless got_lock
        other_lock_expires_at = conn.get(key_name).to_f

        if other_lock_expires_at < cached_current_time
          old_expires_at = conn.getset(key_name, my_lock_expires_at).to_f
          got_lock = (old_expires_at == other_lock_expires_at)
        end
      end

      return false unless got_lock

      begin
        yield
      ensure
        conn.del(key_name) if my_lock_expires_at > (current_time.to_f - 1)
      end
    end

    def check_staleness?
      !@stale_client_timeout.nil?
    end

    def namespaced_key(variable)
      "#{@unique_digest}:#{variable}"
    end

    def current_time
      if @use_local_time
        Time.now
      else
        begin
          instant = SidekiqUniqueJobs.connection(@redis_pool, &:time)
          Time.at(instant[0], instant[1])
        rescue StandardError
          @use_local_time = true
          current_time
        end
      end
    end

    def current_jid
      if @item.key?('at')
        '2'
      else
        @current_jid
      end
    end
  end
end

require 'sidekiq_unique_jobs/lock/prepares_items'
require 'sidekiq_unique_jobs/lock/queue_lock_base'
require 'sidekiq_unique_jobs/lock/run_lock_base'
require 'sidekiq_unique_jobs/lock/until_executed'
require 'sidekiq_unique_jobs/lock/until_executing'
require 'sidekiq_unique_jobs/lock/while_executing'
require 'sidekiq_unique_jobs/lock/until_timeout'
require 'sidekiq_unique_jobs/lock/until_and_while_executing'