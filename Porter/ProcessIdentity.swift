import AppKit
import Darwin
import Foundation

/// Names are for display; IDs identify owners independently of their runtime or port.
struct PortOwner: Sendable {
    let name: String
    let id: String
    var projectRoot: URL? = nil
}

struct ProcessIdentity {
    struct Application: Sendable {
        let name: String
        let bundleID: String
        let path: String

        var isRuntimeLauncher: Bool {
            ProcessIdentity.isRuntime(URL(filePath: path).deletingPathExtension().lastPathComponent)
        }

        func owns(_ executableOrScript: String) -> Bool {
            executableOrScript.hasPrefix(path + "/")
                || executableOrScript.contains("/Library/Application Support/\(bundleID)/")
        }
    }

    struct Service: Sendable {
        let label: String
        let arguments: [String]
    }

    struct Command: Sendable {
        let parentPID: Int32
        let title: String
    }

    static func parseCommands(_ output: String) -> [Int32: Command] {
        var commands: [Int32: Command] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { continue }
            commands[pid] = Command(parentPID: parent, title: parts[2].trimmingCharacters(in: .whitespaces))
        }
        return commands
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    // Read only argv, never the environment that follows it in KERN_PROCARGS2.
    static func arguments(pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(data.prefix(size)))
    }

    static func parseArguments(_ data: [UInt8]) -> [String] {
        guard data.count > 4 else { return [] }
        let count = data.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard count > 0 else { return [] }
        var index = 4
        // Executable path, then alignment padding, then argc NUL-terminated arguments.
        while index < data.count && data[index] != 0 { index += 1 }
        while index < data.count && data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard index < data.count else { break }
            let start = index
            while index < data.count && data[index] != 0 { index += 1 }
            result.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    @MainActor static func runningApplications() -> [Application] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let url = app.bundleURL, let name = app.localizedName else { return nil }
            // Interpreter launcher bundles aren't the application using the interpreter.
            guard !isRuntime(url.deletingPathExtension().lastPathComponent) else { return nil }
            return Application(name: name, bundleID: id, path: url.path)
        }
    }

    static func enclosingApplication(_ path: String) -> Application? {
        let components = URL(filePath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let url = URL(filePath: NSString.path(withComponents: Array(components[...index])))
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        guard !isRuntime(url.deletingPathExtension().lastPathComponent) else { return nil }
        return Application(name: name, bundleID: id, path: url.path)
    }

    static func services(launchctlOutput: String, directories: [URL]) -> [Int32: Service] {
        var running: [String: Int32] = [:]
        for line in launchctlOutput.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int32(parts[0]), pid > 0 else { continue }
            running[String(parts[2])] = pid
        }
        var services: [Int32: Service] = [:]
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, let pid = running[label] else { continue }
                let arguments = plist["ProgramArguments"] as? [String]
                    ?? (plist["Program"] as? String).map { [$0] } ?? []
                services[pid] = Service(label: label, arguments: arguments)
            }
        }
        return services
    }

    static func service(pid: Int32, commands: [Int32: Command], services: [Int32: Service]) -> Service? {
        var current = pid
        var visited = Set<Int32>()
        while current > 1 && visited.insert(current).inserted {
            if let service = services[current] { return service }
            guard let parent = commands[current]?.parentPID else { break }
            current = parent
        }
        return nil
    }

    static func resolve(processName: String, title: String?, executable: String?, arguments: [String],
                        cwd: String?, applications: [Application], service: Service?) -> PortOwner {
        let target = scriptTarget(arguments: arguments, cwd: cwd)
        let sourceDirectory = target.path.map { URL(filePath: $0).deletingLastPathComponent().path } ?? cwd
        let projectRoot = sourceDirectory.flatMap { LivePortScanner.findGitRoot(from: $0) }
        let package = sourceDirectory.flatMap { packageOwner(from: $0) }
        let paths = [executable, target.path].compactMap { $0 }
        let app = applications.sorted { $0.path.count < $1.path.count }.first { app in !app.isRuntimeLauncher && paths.contains(where: app.owns) }
            ?? paths.compactMap(enclosingApplication).first

        // A bundled runtime can also run an independent user's script/project.
        let independentScript = target.path.map { path in app.map { !$0.owns(path) } ?? false } ?? false
        let independentProject = projectRoot.map { root in app.map { !$0.owns(root.path) } ?? false } ?? false
        if let app, !independentScript, !independentProject {
            return PortOwner(name: app.name, id: "app:\(app.bundleID)")
        }
        if let service {
            for prefix in ["homebrew.mxcl.", "sh.brew."] where service.label.hasPrefix(prefix) {
                let formula = String(service.label.dropFirst(prefix.count))
                return PortOwner(name: formula == "omlx" ? "oMLX" : formula, id: "homebrew:\(formula)")
            }
            let serviceTarget = scriptTarget(arguments: service.arguments, cwd: cwd)
            let program = service.arguments.first.map { URL(filePath: $0).lastPathComponent }
            let servicePackage = serviceTarget.path.flatMap { packageOwner(from: URL(filePath: $0).deletingLastPathComponent().path) }
            let name = servicePackage?.name ?? serviceTarget.module ?? serviceTarget.path.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
                ?? program.flatMap { isRuntime($0) ? nil : $0 } ?? service.label
            return PortOwner(name: name, id: "launchd:\(service.label)")
        }
        if let package {
            return PortOwner(name: package.name, id: package.id, projectRoot: projectRoot)
        }
        if let projectRoot {
            return PortOwner(name: projectRoot.lastPathComponent, id: "project:\(projectRoot.path)", projectRoot: projectRoot)
        }
        if LivePortScanner.isDockerProcess(processName) {
            return PortOwner(name: "Docker", id: "runtime:docker")
        }
        if let module = target.module {
            return PortOwner(name: module, id: "module:\(module)")
        }
        if let path = target.path {
            let url = URL(filePath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            let directory = url.deletingLastPathComponent().lastPathComponent
            let name = ["index", "main", "server", "app", "__main__"].contains(stem)
                && LivePortScanner.isMeaningfulDirectoryName(directory) ? directory : stem
            return PortOwner(name: name, id: "script:\(path)")
        }
        if let cwd, !isInfrastructure(cwd), LivePortScanner.isMeaningfulDirectoryName(URL(filePath: cwd).lastPathComponent) {
            return PortOwner(name: URL(filePath: cwd).lastPathComponent, id: "directory:\(cwd)")
        }
        let executableName = executable.map { URL(filePath: $0).lastPathComponent } ?? processName
        let processTitle = title.flatMap { value -> String? in
            guard !value.contains("/"), !value.contains(where: { $0.isWhitespace }), !isRuntime(value) else { return nil }
            return value
        }
        let fallback = processTitle ?? executableName
        let name = fallback.lowercased() == "node" ? "Node" : (fallback.lowercased().hasPrefix("python") ? "Python" : fallback)
        return PortOwner(name: name, id: "executable:\(executable ?? processName)")
    }

    static func isRuntime(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["node", "node.exe", "bun", "bun.exe", "deno", "python", "python3", "ruby", "php", "java", "electron", "sh", "bash", "zsh", "fish", "env"].contains(lower)
            || (lower.hasPrefix("python") && lower.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." })
    }

    static func isNamingBoundary(_ path: String) -> Bool {
        ["/", "/Users", NSHomeDirectory(), "/opt/homebrew", "/usr/local", "/usr/local/Homebrew", "/System", "/Library"].contains(path)
    }

    static func isInfrastructure(_ path: String) -> Bool {
        let path = URL(filePath: path).standardizedFileURL.path
        return ["/", "/Users", "/tmp", "/private/tmp", "/var", "/private/var", NSHomeDirectory()].contains(path)
            || ["/opt/homebrew", "/usr/local", "/usr/bin", "/System", "/Library"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func scriptTarget(arguments: [String], cwd: String?) -> (path: String?, module: String?) {
        guard let program = arguments.first, isRuntime(URL(filePath: program).lastPathComponent) else { return (nil, nil) }
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if ["-e", "--eval", "-p", "--print", "-c"].contains(arg)
                || arg.hasPrefix("--eval=") || arg.hasPrefix("--print=") { return (nil, nil) }
            if arg == "-m" {
                return (nil, index + 1 < arguments.count ? arguments[index + 1] : nil)
            }
            if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(arg) {
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                let switches = ["--", "--inspect", "--inspect-brk", "--enable-source-maps", "--no-warnings", "--trace-warnings", "--watch", "--test", "-u", "-B", "-E", "-s", "-S", "-I", "-O", "-OO"]
                guard switches.contains(arg) || arg.contains("=") else { return (nil, nil) }
                index += 1
                continue
            }
            guard arg.hasPrefix("/") || cwd != nil else { return (nil, nil) }
            let url = arg.hasPrefix("/") ? URL(filePath: arg) : URL(filePath: cwd!).appendingPathComponent(arg)
            let scriptExtensions = ["js", "cjs", "mjs", "ts", "tsx", "py", "rb", "php", "jar"]
            var isDirectory: ObjCBool = false
            let isFile = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            guard scriptExtensions.contains(url.pathExtension.lowercased()) || (arg.contains("/") && isFile) else { return (nil, nil) }
            return (url.standardizedFileURL.path, nil)
        }
        return (nil, nil)
    }

    static func packageOwner(from path: String) -> PortOwner? {
        var directory = URL(filePath: path)
        while !isNamingBoundary(directory.path) {
            let file = directory.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String, !name.isEmpty {
                return PortOwner(name: name, id: "package:\(directory.path)")
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { break }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
