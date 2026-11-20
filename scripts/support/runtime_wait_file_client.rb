require "json"
require "securerandom"

class RuntimeWaitFileClient
  def initialize(root)
    @root = File.join(root, "native-tools")
  end

  def send(action, fields = {}, id: SecureRandom.uuid)
    path = File.join(@root, "requests", id + ".json")
    temporary = path + ".pending"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate({"id" => id, "action" => action}.merge(fields)))
    end
    File.rename(temporary, path)
    id
  end

  def consumed(id)
    await_file_condition { !File.exist?(File.join(@root, "requests", id + ".json")) }
  end

  def ready?(id)
    File.file?(File.join(@root, "responses", id + ".json"))
  end

  def receive(id)
    path = File.join(@root, "responses", id + ".json")
    await_file_condition { File.file?(path) }
    response = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
      info = file.stat
      raise "Unsafe native wait response" unless info.file? && info.uid == Process.uid && info.mode & 0o777 == 0o600 && info.size <= 1_048_576
      JSON.parse(file.read(1_048_577))
    end
    File.delete(path)
    raise "Wrong native wait response identity" unless response["id"] == id
    response
  end

  def request(action, fields = {})
    receive(send(action, fields))
  end
  private

  def await_file_condition
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      value = yield
      return value if value
      raise "Runtime file response timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

end
