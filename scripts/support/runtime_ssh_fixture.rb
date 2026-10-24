require "socket"
require "tmpdir"
require "fileutils"
require "open3"
require "etc"
require "shellwords"

# Real OpenSSH, pinned host key, public-key authentication and an owned relay.
# StrictModes requires safe ancestors, so authorization files cannot live in /tmp.
class RuntimeSSHFixture
  attr_reader :root, :port

  def initialize(force_shell: false)
    @root = Dir.mktmpdir(".qssh-fixture-", File.expand_path("../..", __dir__))
    @mutex = Mutex.new
    @connections = []
    @workers = []
    @stopped = false
    begin
      %w[host client].each do |name|
        _, _, status = Open3.capture3("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", File.join(root, name))
        raise "Ephemeral SSH key generation failed" unless status.success?
      end
      reservation = TCPServer.new("127.0.0.1", 0)
      @server_port = reservation.addr[1]
      reservation.close
      write("authorized_keys", File.read(File.join(root, "client.pub")))
      config = ["Port #{@server_port}", "ListenAddress 127.0.0.1", "HostKey #{root}/host", "PidFile #{root}/sshd.pid",
        "AuthorizedKeysFile #{root}/authorized_keys", "AllowUsers #{Etc.getpwuid.name}", "PasswordAuthentication no",
        "KbdInteractiveAuthentication no", "UsePAM no", "PermitRootLogin no", "StrictModes yes", "PermitTTY yes",
        "AllowTcpForwarding no", "X11Forwarding no", "PermitTunnel no", "PermitUserRC no", "LogLevel ERROR",
        "SetEnv HOME=#{root} ZDOTDIR=#{root}"]
      if force_shell
        write("profile_shell.sh", 'stty sane echo; printf "__PROFILE_SHELL_%s\n" "$$"; while IFS= read -r line; do eval "$line"; done' + "\n")
        config << "ForceCommand /bin/sh #{root}/profile_shell.sh"
        config << "SetEnv SHELL=/bin/sh"
      end
      write("sshd_config", config.join("\n") + "\n")
      _, _, status = Open3.capture3("/usr/sbin/sshd", "-t", "-f", File.join(root, "sshd_config"))
      raise "Private sshd configuration invalid" unless status.success?
      log = File.open(File.join(root, "server.log"), "w", 0600)
      @server_pid = Process.spawn({"PATH" => "/usr/bin:/bin", "HOME" => root}, "/usr/sbin/sshd", "-D", "-e",
        "-f", File.join(root, "sshd_config"), in: File::NULL, out: log, err: log, unsetenv_others: true)
      log.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      loop do
        if Process.waitpid(@server_pid, Process::WNOHANG)
          @server_pid = nil
          raise "Owned sshd exited before readiness"
        end
        begin
          TCPSocket.new("127.0.0.1", @server_port).close
          break
        rescue Errno::ECONNREFUSED
          raise "Private sshd readiness timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.025
        end
      end
      @relay = TCPServer.new("127.0.0.1", 0)
      @port = @relay.addr[1]
      host = "[127.0.0.1]:#{@port} "
      write("known_hosts", host + File.read(File.join(root, "host.pub")))
      write("wrong_known_hosts", host + File.read(File.join(root, "client.pub")))
      @acceptor = Thread.new { accept_connections }
    rescue
      stop
      raise
    end
  end

  def arguments(host_key: "known_hosts", identity: "client")
    script = 'stty sane echo; printf "__SSH_READY\n"; while IFS= read -r line; do eval "$line"; done'
    ["-F", "/dev/null", "-tt", "-p", @port.to_s, "-i", File.join(root, identity),
      "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "ConnectionAttempts=1",
      "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=#{root}/#{host_key}",
      "-o", "GlobalKnownHostsFile=/dev/null", "#{Etc.getpwuid.name}@127.0.0.1", Shellwords.join(["/bin/sh", "-c", script])]
  end

  def disconnect(reset: false)
    if reset
      @mutex.synchronize do
        @connections.flatten.each do |socket|
          next if socket.closed?
          socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
          socket.close
        end
      end
    else
      @mutex.synchronize { @connections.dup }.flatten.each { |socket| close_socket(socket) }
    end
  end

  def stop
    begin
      @stopped = true
      @relay.close if @relay && !@relay.closed?
      disconnect
      @acceptor&.join(2)
      @workers.each { |worker| worker.join(2) }
      raise "Owned SSH relay worker did not stop" if @workers.any?(&:alive?) || @acceptor&.alive?
    ensure
      begin
        if @server_pid
          unless Process.waitpid(@server_pid, Process::WNOHANG)
            Process.kill("TERM", @server_pid)
            Process.waitpid(@server_pid)
          end
          @server_pid = nil
        end
      ensure
        FileUtils.remove_entry(root) if File.directory?(root)
      end
    end
  end

  private

  def write(name, value)
    File.open(File.join(root, name), File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(value) }
  end

  def close_socket(socket)
    @mutex.synchronize do
      return if socket.closed?
      begin
        socket.shutdown(Socket::SHUT_RDWR)
      rescue Errno::ENOTCONN
        # Peer already ended this same owned connection; closing is still required.
        nil
      ensure
        socket.close
      end
    end
  end

  def accept_connections
    until @stopped
      downstream = @relay.accept
      @workers << Thread.new(downstream) do |client|
        upstream = TCPSocket.new("127.0.0.1", @server_port)
        pair = [client, upstream]
        @mutex.synchronize { @connections << pair }
        begin
          directions = pair.zip(pair.reverse).map do |source, destination|
            Thread.new do
              begin
                IO.copy_stream(source, destination)
              rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::EBADF
                # Deliberate transport drop or normal SSH disconnect.
                nil
              ensure
                pair.each { |socket| close_socket(socket) }
              end
            end
          end
          directions.each(&:join)
        ensure
          @mutex.synchronize { @connections.delete(pair) }
          pair.each { |socket| close_socket(socket) }
        end
      end
    end
  rescue IOError, Errno::EBADF
    raise unless @stopped
  end
end
