log_path = File.join(AnilCoopDev::PROFILE, "coop-loader.log")
File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} postload reached; scene=#{defined?(Scene_Map)}") }
begin
  load "CoopDev/coop.rb"
  load "CoopDev/coop_battle.rb"
  load "CoopDev/battle_qa.rb" if ENV["ANIL_COOP_QA_BOT"]
  File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} presence script loaded") }
rescue Exception => e
  File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}") }
end
