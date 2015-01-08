require 'openssl'
require 'securerandom'
require 'socket'
require 'time'

# = Statsd: A Statsd client (https://github.com/etsy/statsd)
#
# @example Set up a global Statsd client for a server on localhost:8125
#   $statsd = Statsd.new 'localhost', 8125
# @example Send some stats
#   $statsd.increment 'garets'
#   $statsd.timing 'glork', 320
# @example Use {#time} to time the execution of a block
#   $statsd.time('account.activate') { @account.activate! }
# @example Create a namespaced statsd client and increment 'account.activate'
#   statsd = Statsd.new('localhost').tap{|sd| sd.namespace = 'account'}
#   statsd.increment 'activate'
class Statsd
  # A namespace to prepend to all statsd calls.
  attr_accessor :namespace

  #characters that will be replaced with _ in stat names
  RESERVED_CHARS_REGEX = /[\:\|\@]/

  # Digest object as a constant
  SHA256 = OpenSSL::Digest::SHA256.new

  class << self
    # Set to any standard logger instance (including stdlib's Logger) to enable
    # stat logging using logger.debug
    attr_accessor :logger
  end

  # @param [String] host your statsd host
  # @param [Integer] port your statsd port
  def initialize(host, port=8125, key=nil)
    @host, @port, @key = host, port, key
    @ip = Addrinfo.ip(host).ip_address
  end

  # Sends an increment (count = 1) for the given stat to the statsd server.
  #
  # @param stat (see #count)
  # @param sample_rate (see #count)
  # @see #count
  def increment(stat, sample_rate=1); count stat, 1, sample_rate end

  # Sends a decrement (count = -1) for the given stat to the statsd server.
  #
  # @param stat (see #count)
  # @param sample_rate (see #count)
  # @see #count
  def decrement(stat, sample_rate=1); count stat, -1, sample_rate end

  # Sends an arbitrary count for the given stat to the statsd server.
  #
  # @param [String] stat stat name
  # @param [Integer] count count
  # @param [Integer] sample_rate sample rate, 1 for always
  def count(stat, count, sample_rate=1); send stat, count, 'c', sample_rate end

  # Sends an arbitary gauge value for the given stat to the statsd server.
  #
  # @param [String] stat stat name.
  # @param [Numeric] gauge value.
  # @example Report the current user count:
  #   $statsd.gauge('user.count', User.count)
  def gauge(stat, value)
    send stat, value, 'g'
  end

  # Sends a timing (in ms) for the given stat to the statsd server. The
  # sample_rate determines what percentage of the time this report is sent. The
  # statsd server then uses the sample_rate to correctly track the average
  # timing for the stat.
  #
  # @param stat stat name
  # @param [Integer] ms timing in milliseconds
  # @param [Integer] sample_rate sample rate, 1 for always
  def timing(stat, ms, sample_rate=1); send stat, ms, 'ms', sample_rate end

  # Reports execution time of the provided block using {#timing}.
  #
  # @param stat (see #timing)
  # @param sample_rate (see #timing)
  # @yield The operation to be timed
  # @see #timing
  # @example Report the time (in ms) taken to activate an account
  #   $statsd.time('account.activate') { @account.activate! }
  def time(stat, sample_rate=1)
    start = Time.now
    result = yield
    timing(stat, ((Time.now - start) * 1000).round(5), sample_rate)
    result
  end

  private

  def sampled(sample_rate)
    yield unless sample_rate < 1 and rand > sample_rate
  end

  def send(stat, delta, type, sample_rate=1)
    sampled(sample_rate) do
      prefix = "#{@namespace}." unless @namespace.nil?
      stat = stat.to_s.gsub('::', '.').gsub(RESERVED_CHARS_REGEX, '_')
      send_to_socket("#{prefix}#{stat}:#{delta}|#{type}#{'|@' << sample_rate.to_s if sample_rate < 1}")
    end
  end

  def send_to_socket(message)
    self.class.logger.debug {"Statsd: #{message}"} if self.class.logger
    if @key.nil?
      socket.send(message, 0, @ip, @port)
    else
      socket.send(signed_payload(message), 0, @ip, @port)
    end
  rescue => boom
    self.class.logger.error {"Statsd: #{boom.class} #{boom}"} if self.class.logger
  end

  def signed_payload(message)
    payload = timestamp + nonce + message
    signature = OpenSSL::HMAC.digest(SHA256, @key, payload)
    signature + payload
  end

  def timestamp
    [Time.now.to_i].pack("Q<")
  end

  def nonce
    SecureRandom.random_bytes(4)
  end

  def socket; @socket ||= UDPSocket.new end
end
