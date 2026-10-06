# Template for hackmajoris/homebrew-apps. The release workflow fills in
# __VERSION__ and __SHA256__ and pushes the result to Casks/apprec.rb.
cask "apprec" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/hackmajoris/apprec/releases/download/v#{version}/AppRec.zip"
  name "AppRec"
  desc "Menu bar recorder that transcribes and summarizes app audio on device"
  homepage "https://hackmajoris.github.io/apprec/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "AppRec.app"

  postflight_steps do
    run "xattr",
        args: ["-rd", "com.apple.quarantine", "{{appdir}}/AppRec.app"]
  end

  uninstall quit: "com.hackmajoris.AppRec"

  zap trash: [
    "~/Library/Application Support/AppRec",
    "~/Library/Preferences/com.hackmajoris.AppRec.plist",
  ]
end
