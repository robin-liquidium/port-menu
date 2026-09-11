import Foundation
import Testing
@testable import Port_Menu

struct ProcessIdentityTests {
    private func resolve(_ name: String = "node", title: String? = nil, executable: String? = "/opt/homebrew/bin/node",
                         arguments: [String] = ["node"], cwd: String? = "/",
                         apps: [ProcessIdentity.Application] = [], service: ProcessIdentity.Service? = nil) -> PortOwner {
        ProcessIdentity.resolve(processName: name, title: title, executable: executable,
                                arguments: arguments, cwd: cwd, applications: apps, service: service)
    }

    @Test func identifiesAnyBundledAppAndItsHelper() {
        let app = ProcessIdentity.Application(name: "Example Studio", bundleID: "org.example.studio", path: "/Applications/Example Studio.app")
        let owner = resolve(executable: app.path + "/Contents/Frameworks/Helper.app/Contents/MacOS/node", apps: [app])
        #expect(owner.name == "Example Studio")
        #expect(owner.id == "app:org.example.studio")
        #expect(owner.projectRoot == nil)
    }

    @Test func outerAppWinsOverItsHelperBundle() {
        let app = ProcessIdentity.Application(name: "Example Studio", bundleID: "org.example.studio", path: "/Applications/Example Studio.app")
        let helper = ProcessIdentity.Application(name: "Example Helper", bundleID: "org.example.helper", path: app.path + "/Contents/Helper.app")
        let owner = resolve(executable: helper.path + "/Contents/MacOS/node", apps: [helper, app])
        #expect(owner.name == "Example Studio")
    }

    @Test func identifiesRaycastFromItsBundledRuntimeWithoutProcessTitle() {
        let app = ProcessIdentity.Application(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app")
        let owner = resolve(executable: NSHomeDirectory() + "/Library/Application Support/com.raycast.macos/node/runtime/bin/node", apps: [app])
        #expect(owner.name == "Raycast")
        #expect(owner.id == "app:com.raycast.macos")
    }

    @Test func doesNotHideAProcessJustBecauseItsTitleMatches() {
        let owner = resolve(title: "Raycast Backend")
        #expect(owner.name == "Node")
        #expect(owner.id != "app:com.raycast.macos")
        let port = ActivePort(port: 8000, pid: 1, projectName: "oMLX", branch: "", startTime: nil, ownerID: owner.id)
        #expect(!port.isHiddenBackgroundService)
    }

    @Test func ignoresUnrelatedTerminalApplication() {
        let terminal = ProcessIdentity.Application(name: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")
        #expect(resolve(apps: [terminal]).name == "Node")
    }

    @Test func canonicalizesHomebrewServiceAcrossLabelVersions() {
        for label in ["homebrew.mxcl.omlx", "sh.brew.omlx"] {
            let owner = resolve("Python", service: .init(label: label, arguments: ["/opt/homebrew/opt/omlx/bin/omlx", "serve"]))
            #expect(owner.name == "oMLX")
            #expect(owner.id == "homebrew:omlx")
            #expect(owner.projectRoot == nil)
        }
        let other = resolve(service: .init(label: "sh.brew.redis", arguments: ["/opt/homebrew/opt/redis/bin/redis-server"]))
        #expect(other.name == "redis")
        #expect(other.id == "homebrew:redis")
    }

    @Test func pythonLauncherNameCannotOverrideServiceIdentity() {
        let python = ProcessIdentity.Application(name: "omlx-server", bundleID: "org.python.python", path: "/opt/homebrew/Python.app")
        let owner = resolve("Python", executable: python.path + "/Contents/MacOS/Python", apps: [python],
                            service: .init(label: "sh.brew.omlx", arguments: ["omlx", "serve"]))
        #expect(owner.name == "oMLX")
        #expect(owner.id == "homebrew:omlx")
    }

    @Test func shellWrappedServiceUsesItsLabelInsteadOfShellName() {
        let owner = resolve(service: .init(label: "com.example.proxy", arguments: ["/bin/sh", "-c", "exec secret-command"]))
        #expect(owner.name == "com.example.proxy")
        #expect(owner.id == "launchd:com.example.proxy")
    }

    @Test func identifiesGenericLaunchAgentFromScript() {
        let owner = resolve(service: .init(label: "org.example.worker", arguments: ["/opt/homebrew/bin/node", "/tmp/tasks/worker.mjs"]))
        #expect(owner.name == "worker")
        #expect(owner.id == "launchd:org.example.worker")
    }

    @Test func followsLaunchServiceParentButHandlesCycles() {
        let commands = ProcessIdentity.parseCommands(" 100 1 /bin/service\n 101 100 node\n 102 103 node\n 103 102 node\n invalid")
        let services: [Int32: ProcessIdentity.Service] = [100: .init(label: "org.example.worker", arguments: [])]
        #expect(ProcessIdentity.service(pid: 101, commands: commands, services: services)?.label == "org.example.worker")
        #expect(ProcessIdentity.service(pid: 102, commands: commands, services: services) == nil)
        #expect(commands[100]?.title == "/bin/service")
    }

    @Test func unknownRuntimeDoesNotBecomeHomebrewOrVar() {
        let owner = resolve(title: "node", cwd: "/opt/homebrew/var")
        #expect(owner.name == "Node")
        #expect(owner.projectRoot == nil)
        #expect(LivePortScanner.findGitRoot(from: "/opt/homebrew/var") == nil)
    }

    @Test func pythonModuleHasMeaningfulName() {
        let owner = resolve("Python", executable: "/opt/homebrew/bin/python3", arguments: ["python3", "-u", "-m", "http.server"])
        #expect(owner.name == "http.server")
        #expect(owner.id == "module:http.server")
    }

    @Test func scriptParsingPreservesSpacesAndSkipsRuntimeFlags() {
        let target = ProcessIdentity.scriptTarget(arguments: ["node", "--require", "/tmp/preload.js", "src/my server.mjs", "--port", "4000"], cwd: "/tmp/my project")
        #expect(target.path == "/tmp/my project/src/my server.mjs")
        #expect(target.module == nil)
        #expect(ProcessIdentity.scriptTarget(arguments: ["node", "-e", "SECRET=anything.js"], cwd: "/").path == nil)
        #expect(ProcessIdentity.scriptTarget(arguments: ["node", "--eval=anything.js"], cwd: "/").path == nil)
        #expect(ProcessIdentity.scriptTarget(arguments: ["node", "-p", "anything.js"], cwd: "/").path == nil)
    }

    @Test func extensionlessEntryPointIsRecognizedAndOptionValuesAreNotScripts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = directory.appendingPathComponent("uvicorn")
        try Data("# entry point".utf8).write(to: entry)
        #expect(ProcessIdentity.scriptTarget(arguments: ["python3", entry.path], cwd: "/").path == entry.path)
        #expect(ProcessIdentity.scriptTarget(arguments: ["node", "--unknown-option", entry.path], cwd: "/").path == nil)
    }

    @Test func argvParsingDoesNotReadEnvironment() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/opt/homebrew/bin/node\0\0node\0/tmp/my server.js\0\0SECRET=do-not-read\0".utf8)
        #expect(ProcessIdentity.parseArguments(bytes) == ["node", "/tmp/my server.js", ""])
        #expect(ProcessIdentity.parseArguments([]).isEmpty)
    }

    @Test func packageNameAndGitBranchBelongToTheScriptProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data(#"{"name":"@example/api"}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        let app = ProcessIdentity.Application(name: "Example Studio", bundleID: "org.example.studio", path: "/Applications/Example Studio.app")
        let owner = resolve(executable: app.path + "/Contents/node", arguments: ["node", directory.appendingPathComponent("src/server.js").path], apps: [app])
        #expect(owner.name == "@example/api")
        #expect(owner.id == "package:\(directory.path)")
        #expect(owner.projectRoot?.path == directory.path)
    }

    @Test func nestedGitProjectDoesNotInheritAnUnrelatedParentPackage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("independent-project")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data(#"{"name":"parent-package"}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        #expect(resolve(cwd: nested.path).name == "independent-project")
    }

    @Test func malformedPackageFallsBackToGitProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("package.json"))
        #expect(resolve(cwd: directory.path).name == directory.lastPathComponent)
    }

    @Test func launchServiceUsesLabelInsidePlistNotFilename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "org.example.worker", "ProgramArguments": ["node", "/tmp/worker.js"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("different-name.plist"))
        let services = ProcessIdentity.services(launchctlOutput: "PID Status Label\n123 0 org.example.worker\n- 0 inactive", directories: [directory])
        #expect(services[123]?.label == "org.example.worker")
        #expect(services.count == 1)
    }

    @Test func dockerAndMeaningfulDirectoriesStillHaveNames() {
        #expect(resolve("com.docke", executable: nil).name == "Docker")
        #expect(resolve("beam.smp", executable: nil, cwd: "/tmp/api-backend").name == "api-backend")
        #expect(resolve("beam.smp", executable: nil, cwd: "/tmp/api-backend/_build").name == "beam.smp")
    }
}
