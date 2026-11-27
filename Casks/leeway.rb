# Homebrew cask for Leeway. The release workflow updates `version` and `sha256` after each release.
# Install:  brew tap d0s1nt/leeway https://github.com/d0s1nt/leeway
#           brew install --cask leeway
cask "leeway" do
  version "1.1.0"
  sha256 "d8564aa63c12088a07102fa4b0d1a6e0aa5fdb9af1dc9a4e9fcab020354be73c"

  url "https://github.com/d0s1nt/leeway/releases/download/v#{version}/Leeway-#{version}.dmg"
  name "Leeway"
  desc "Menu bar view of how much of each AI coding tool's allowance is left"
  homepage "https://github.com/d0s1nt/leeway"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Leeway.app"

  # A clean quit leaves the Launch at Login agent loaded but idle, so upgrading keeps that setting.
  uninstall quit: "ai.cynaptix.leeway"

  zap launchctl: "ai.cynaptix.leeway",
      trash:     [
        "~/Library/Application Support/ai.cynaptix.leeway",
        "~/Library/LaunchAgents/ai.cynaptix.leeway.plist",
        "~/Library/Logs/Leeway.log",
        "~/Library/Preferences/ai.cynaptix.leeway.plist",
      ]

  caveats <<~EOS
    Leeway isn't notarized by Apple yet, so macOS blocks the first launch.
    Open it once, click Done, then go to System Settings > Privacy & Security
    and click Open Anyway next to Leeway. Upgrading quits Leeway; open it
    again from Applications (macOS may ask for Open Anyway again).
  EOS
end
