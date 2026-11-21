# Template for the owner's tap (github.com/hrdikpande/homebrew-tap): `brew install --cask hrdikpande/tap/ports`.
# Release automation fills in `version` and `sha256` (from dist/SHA256SUMS.txt) for each tag.
# Official homebrew/cask needs a notarized build (and notability) first.
cask "ports" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_Ports-#{version}.zip"

  url "https://github.com/hrdikpande/DEVport-watcher/releases/download/v#{version}/Ports-#{version}.zip"
  name "Ports"
  desc "Menu bar app that shows what is listening locally, why, and how to stop it safely"
  homepage "https://github.com/hrdikpande/DEVport-watcher"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates false
  depends_on macos: ">= :sonoma"

  app "Ports.app"
  binary "#{appdir}/Ports.app/Contents/Helpers/ports"

  uninstall quit: "local.portwatch.ports"

  zap trash: [
    "~/Library/Application Support/Ports",
    "~/Library/Preferences/local.portwatch.ports.plist",
    "~/Library/Caches/local.portwatch.ports",
  ]
end
