# Hito 0: development-only save isolation. No networking or gameplay changes.
# Loaded by mkxp-z before Scripts.rxdata, so SaveData and Multi Save see this path.
module AnilCoopDev
  PROFILE_ID = File.read(File.join(__dir__, "profile-id.txt")).strip.freeze
  raise "Launch this test copy using tools/h0.py launch" unless
    ENV["ANIL_COOP_PROFILE_ID"] == PROFILE_ID

  PROFILE = File.realpath(File.join(__dir__, "..", "..", "profile")).freeze
  SAVE_DIR = File.realpath(File.join(PROFILE, "saves")).freeze
  expected = File.expand_path(File.join(PROFILE, "saves"))
  raise "Invalid private save directory" unless SAVE_DIR == expected
  raise "Profile marker mismatch" unless
    File.read(File.join(PROFILE, "profile-id.txt")).strip == PROFILE_ID

  System.singleton_class.send(:define_method, :data_directory) { SAVE_DIR }
  raise "Save redirection failed" unless System.data_directory == SAVE_DIR
  File.open(File.join(PROFILE, "bootstrap-loaded.txt"), "w") do |f|
    f.puts("profile_id=#{PROFILE_ID}")
    f.puts("save_directory=#{System.data_directory}")
    f.puts("ruby=#{RUBY_VERSION}")
    f.puts("time=#{Time.now.utc}")
  end
end

# Añil invokes mainFunction directly, without rgss_main. mkxp's postloadScript
# therefore never fires. Load our map hook only after the original plugins finish.
$anil_coop_late_trace = TracePoint.new(:return) do |event|
  next unless event.method_id == :runPlugins && event.defined_class.to_s.include?("PluginManager")
  $anil_coop_late_trace.disable
  load "CoopDev/loader.rb" if File.file?("CoopDev/loader.rb")
end
$anil_coop_late_trace.enable
