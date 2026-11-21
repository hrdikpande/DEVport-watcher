# Source-build alternative for users without a notarized build: `brew install hrdikpande/tap/ports`.
# Builds the CLI and the menu bar app from the tagged source with the Xcode toolchain.
class Ports < Formula
  desc "What is running locally, why, whether it is safe, and how to stop it"
  homepage "https://github.com/hrdikpande/DEVport-watcher"
  url "https://github.com/hrdikpande/DEVport-watcher/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_SOURCE_TARBALL"
  license "MIT"
  head "https://github.com/hrdikpande/DEVport-watcher.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "ports"
    bin.install ".build/release/ports"
    ENV["CI"] = "1"                                # build_app.sh: never install into ~/Applications or quit apps
    system "./Scripts/build_app.sh", "--no-install"
    prefix.install "build/Ports.app"
  end

  def caveats
    <<~EOS
      The menu bar app was built into:
        #{opt_prefix}/Ports.app
      To use it, copy it to /Applications (or ~/Applications):
        cp -R #{opt_prefix}/Ports.app ~/Applications/
    EOS
  end

  test do
    assert_match "What is running locally", shell_output("#{bin}/ports --help")
    system bin/"ports", "next-free", "--from", "40000"
  end
end
