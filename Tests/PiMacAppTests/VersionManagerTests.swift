import Testing

@testable import PiMacApp

struct VersionManagerTests {
  @Test func parsesUserAndProjectPackages() {
    let output = """
      User packages:
        npm:pi-tools
          /Users/test/.pi/agent/npm/node_modules/pi-tools
      Project packages:
        git:github.com/example/project-extension
          /tmp/project/.pi/git/github.com/example/project-extension
      """

    let packages = VersionManagerModel.parsePackageList(output)

    #expect(packages.count == 2)
    #expect(packages[0].source == "npm:pi-tools")
    #expect(packages[0].scope == "用户")
    #expect(packages[1].scope == "项目")
  }

  @Test func buildsInstallCommandsWithoutShellInterpolation() {
    #expect(
      VersionManagerModel.installArguments(source: " npm:@scope/tools@1.0.0 ", local: false)
        == ["install", "npm:@scope/tools@1.0.0"])
    #expect(
      VersionManagerModel.installArguments(source: "git:github.com/example/tools", local: true)
        == ["install", "git:github.com/example/tools", "--local"])
    #expect(
      VersionManagerModel.installArguments(source: "/tmp/local tools", local: false)
        == ["install", "/tmp/local tools"])
    #expect(VersionManagerModel.installArguments(source: "   ", local: false) == nil)
    #expect(VersionManagerModel.installArguments(source: "--help", local: false) == nil)
    #expect(VersionManagerModel.installArguments(source: "npm:tools\nother", local: false) == nil)
  }

  @Test func removesOnlyTheSelectedScope() {
    let packages = VersionManagerModel.parsePackageList(
      """
      User packages:
        npm:tools
          /tmp/user/tools
      Project packages:
        npm:tools
          /tmp/project/tools
      """)
    #expect(packages.count == 2)
    #expect(VersionManagerModel.removeArguments(for: packages[0]) == ["remove", "npm:tools"])
    #expect(
      VersionManagerModel.removeArguments(for: packages[1])
        == ["remove", "npm:tools", "--local"])
  }

  @Test func comparesSemanticVersions() {
    #expect(VersionManagerModel.isNewer("0.86.0", than: "0.85.9"))
    #expect(VersionManagerModel.isNewer("1.0.1", than: "1.0.0"))
    #expect(!VersionManagerModel.isNewer("1.0.0", than: "1.0.0"))
    #expect(!VersionManagerModel.isNewer("0.9.9", than: "1.0.0"))
  }
}
