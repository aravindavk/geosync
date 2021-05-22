require "yaml"
require "json"

struct Config
  include YAML::Serializable
  include JSON::Serializable

  property src = "",
    target = "",
    crawl_dir = "",
    stime_xattr = "",
    ssh_port = 22,
    ssh_command = "ssh",
    rsync_command = "rsync",
    syncjobs = 4

  def target_node
    target_node, _, _ = @target.rpartition(":")
    target_node
  end

  def target_path
    _, _, target_path = @target.rpartition(":")
    target_path
  end

  def ssh_ctrl_path
    "/root/.ssh/controlmasters/root@#{target_node}:#{@ssh_port}"
  end

  def initialize
  end
end

# ```
# config_mgr = ConfigManager.new("sample_config.yaml")
# puts config_mgr.config
# puts config_mgr.config.target_node
# puts config_mgr.config.target_path
# puts config_mgr.config.ssh_ctrl_path
# ```
class ConfigManager
  private record ReloadConfig
  private record FetchConfig, return_channel : Channel(Config)

  @requests = Channel(ReloadConfig | FetchConfig).new

  def initialize(@config_file : String)
    @config = Config.new
    load
    spawn(name: "config_manager") do
      loop do
        case command = @requests.receive
        when ReloadConfig
          load
        when FetchConfig
          command.return_channel.send @config
        end
      end
    end
  end

  private def load
    @config = Config.from_yaml(File.read(@config_file))
  end

  def config
    Channel(Config).new.tap { |return_channel|
      @requests.send FetchConfig.new(return_channel)
    }.receive
  end

  def reload
    @requests.send ReloadConfig.new
  end
end
