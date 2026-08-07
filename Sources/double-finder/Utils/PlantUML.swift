import Foundation

/// Resolves how to run PlantUML for ```plantuml fences in the Lister markdown
/// preview. Mirrors SevenZip: bundled jar (shipped in the .app) → Homebrew jar
/// → a `plantuml` wrapper script on PATH. The jar paths need a working Java
/// runtime — and /usr/bin/java exists on EVERY macOS as a stub, so presence is
/// not enough: only a /usr/libexec/java_home success counts (design §6).
enum PlantUML {
    enum Invocation: Equatable {
        case jar(java: String, jar: String)   // java -jar plantuml.jar
        case script(String)                    // brew wrapper (carries its own JRE dep)
    }
    enum Resolution: Equatable {
        case ok(Invocation)
        case missingJar        // no jar and no wrapper anywhere
        case missingJava       // jar found but no usable Java runtime
    }

    static let jarSearchPaths = [
        "/opt/homebrew/opt/plantuml/libexec/plantuml.jar",
        "/usr/local/opt/plantuml/libexec/plantuml.jar",
    ]
    static let scriptSearchPaths = ["/opt/homebrew/bin/plantuml", "/usr/local/bin/plantuml"]

    /// plantuml.jar shipped in the .app (Contents/Resources), or the repo
    /// vendor/ copy when bare-running a dev build.
    static func bundledJarPath() -> String? {
        if let res = Bundle.main.resourcePath {
            let p = res + "/plantuml.jar"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return DiagramSupport.devVendorPath("plantuml/plantuml.jar")
    }

    /// Real Java runtime via /usr/libexec/java_home (exit 0 → JAVA_HOME printed).
    /// Result cached per launch — java_home spawns a process. Blocking: call off
    /// the main actor (DiagramRenderer does). The cache is deliberately
    /// unsynchronized: resolve() is only ever reached through DiagramRenderer's
    /// single-slot serialized render chain, so there is never a concurrent
    /// caller — add locking before calling resolve()/javaPath() from anywhere else.
    private static var cachedJava: String??
    static func javaPath() -> String? {
        if let cached = cachedJava { return cached }
        var found: String?
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                let java = s.trimmingCharacters(in: .whitespacesAndNewlines) + "/bin/java"
                if FileManager.default.isExecutableFile(atPath: java) { found = java }
            }
        }
        cachedJava = .some(found)
        return found
    }

    static func resolve() -> Resolution {
        let fm = FileManager.default
        let jar = bundledJarPath() ?? jarSearchPaths.first { fm.fileExists(atPath: $0) }
        let script = scriptSearchPaths.first { fm.isExecutableFile(atPath: $0) }
        if let jar {
            if let java = javaPath() { return .ok(.jar(java: java, jar: jar)) }
            if let script { return .ok(.script(script)) }   // brew wrapper may still find a JRE
            return .missingJava
        }
        if let script { return .ok(.script(script)) }
        return .missingJar
    }
}
