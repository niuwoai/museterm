require "socket"
require "json"
require "securerandom"

class RuntimeProbeClient
  def initialize(root)
    @socket = UNIXSocket.new(File.join(root, "runtime.sock"))
    @capability = File.read(File.join(root, "ui-capability"))
    @buffer = "".b
  end

  def request(action, fields = {}, id: SecureRandom.uuid)
    message = {"protocolVersion" => 3, "id" => id, "action" => action, "capability" => @capability}.merge(fields)
    send_bytes(JSON.generate(message) + "\n")
    response = receive
    raise "Wrong response identity" unless response["id"].casecmp?(id)
    response
  end

  def send_bytes(bytes)
    remaining = bytes.b
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until remaining.empty?
      raise "Socket write timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      count = @socket.write_nonblock(remaining, exception: false)
      if count == :wait_writable
        IO.select(nil, [@socket], nil, 0.1)
      else
        remaining = remaining.byteslice(count..)
      end
    end
  end

  def receive(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      if (newline = @buffer.index("\n"))
        line = @buffer.slice!(0..newline)
        return JSON.parse(line)
      end
      raise "Socket read timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      bytes = @socket.read_nonblock(16_384, exception: false)
      case bytes
      when :wait_readable then IO.select([@socket], nil, nil, 0.1)
      when nil then raise EOFError, "Client disconnected"
      else @buffer << bytes
      end
    end
  end

  def close
    @socket.close
  end
end
