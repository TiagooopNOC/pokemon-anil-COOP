log_path = File.join(AnilCoopDev::PROFILE, "coop-loader.log")
File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} postload reached; scene=#{defined?(Scene_Map)}") }
begin
  load "CoopDev/coop.rb"
  load "CoopDev/coop_team.rb"
  load "CoopDev/coop_trainers.rb"
  load "CoopDev/coop_challenge.rb"
  load "CoopDev/coop_result.rb"
  load "CoopDev/coop_battle.rb"
  load "CoopDev/coop_speed.rb"
  load "CoopDev/coop_menus.rb"
  load "CoopDev/coop_title.rb"
  load "CoopDev/coop_online.rb"
  load "CoopDev/coop_online_screen.rb"
  load "CoopDev/coop_online_map.rb"
  load "CoopDev/coop_online_team.rb"
  load "CoopDev/coop_online_invites.rb"
  load "CoopDev/coop_pvp.rb"
  load "CoopDev/online_invite_qa.rb" if ENV["ANIL_COOP_INVITE_QA"] == "1"
  load "CoopDev/online_team_qa.rb" if ENV["ANIL_COOP_ONLINE_TEAM_QA"] == "1"
  load "CoopDev/online_qa.rb" if ENV["ANIL_COOP_ONLINE_QA"] == "1"
  load "CoopDev/menu_qa.rb" if ENV["ANIL_COOP_MENU_QA"] == "1"
  load "CoopDev/presence_qa.rb" if ["1", "network", "labels", "followers"].include?(ENV["ANIL_COOP_PRESENCE_QA"])
  load "CoopDev/story_qa.rb" if ENV["ANIL_COOP_STORY_QA"] == "inspect"
  load "CoopDev/challenge_qa.rb" if ENV["ANIL_COOP_CHALLENGE_QA"]
  load "CoopDev/battle_qa.rb" if ENV["ANIL_COOP_QA_BOT"]
  load "CoopDev/speed_qa.rb" if ENV["ANIL_COOP_SPEED_QA"] == "1"
  File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} presence script loaded") }
rescue Exception => e
  File.open(log_path, "a") { |f| f.puts("#{Time.now.utc} #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}") }
end
