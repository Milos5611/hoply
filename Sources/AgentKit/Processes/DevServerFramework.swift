import Foundation

public enum DevServerFramework: String, Sendable, CaseIterable {
    case nextJS, nuxt, astro, svelteKit, remix, webpackDevServer, vite
    case uvicorn, gunicorn, flask, django, pythonHTTPServer, rails, puma
    case dotnet, bun, deno, node, go, rust, php, python, ruby, java
    case other

    public var displayName: String {
        switch self {
        case .nextJS: return "Next.js"
        case .nuxt: return "Nuxt"
        case .astro: return "Astro"
        case .svelteKit: return "SvelteKit"
        case .remix: return "Remix"
        case .webpackDevServer: return "webpack"
        case .vite: return "Vite"
        case .uvicorn: return "Uvicorn"
        case .gunicorn: return "Gunicorn"
        case .flask: return "Flask"
        case .django: return "Django"
        case .pythonHTTPServer: return "http.server"
        case .rails: return "Rails"
        case .puma: return "Puma"
        case .dotnet: return ".NET"
        case .bun: return "Bun"
        case .deno: return "Deno"
        case .node: return "Node"
        case .go: return "Go"
        case .rust: return "Rust"
        case .php: return "PHP"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .java: return "Java"
        case .other: return "Server"
        }
    }

    public var isRuntime: Bool {
        switch self {
        case .dotnet, .bun, .deno, .node, .go, .rust, .php, .python, .ruby, .java: return true
        default: return false
        }
    }

    public var isSpecific: Bool { self != .other && !isRuntime }

    var specificity: Int { isSpecific ? 2 : (isRuntime ? 1 : 0) }

    public static func detect(_ process: ScannedProcess) -> DevServerFramework {
        detect(executable: process.executable, arguments: process.arguments)
    }

    public static func detect(executable: String?, arguments: [String]) -> DevServerFramework {
        let lowered = arguments.map { $0.lowercased() }
        let words = Array(lowered.filter { !$0.hasPrefix("-") }.prefix(4))
        let names = words.map(programName)
        let path = (executable ?? arguments.first ?? "").lowercased()
        let program = programName(path)

        func named(_ candidates: String...) -> Bool { names.contains { candidates.contains($0) } }
        func inPath(_ fragment: String) -> Bool { words.contains { $0.contains(fragment) } }
        func module(_ name: String) -> Bool {
            lowered.indices.contains { lowered[$0] == "-m" && $0 + 1 < lowered.count && lowered[$0 + 1] == name }
        }

        if named("next", "next-server") || inPath("/node_modules/next/") { return .nextJS }
        if named("nuxt", "nuxi") || inPath("/node_modules/nuxt/") || inPath("/node_modules/nuxi/") { return .nuxt }
        if named("astro") || inPath("/node_modules/astro/") { return .astro }
        if named("svelte-kit") || inPath("/@sveltejs/kit/") { return .svelteKit }
        if named("remix", "remix-serve") || inPath("/@remix-run/") { return .remix }
        if named("webpack-dev-server") || inPath("/node_modules/webpack-dev-server/")
            || (named("webpack") && words.contains("serve")) { return .webpackDevServer }
        if named("vite", "vite.js") || inPath("/node_modules/vite/") { return .vite }
        if named("uvicorn") || module("uvicorn") { return .uvicorn }
        if named("gunicorn") || module("gunicorn") { return .gunicorn }
        if named("flask") || module("flask") { return .flask }
        if (named("manage.py") && words.contains("runserver")) || named("django-admin") || module("django") {
            return .django
        }
        if module("http.server") || module("simplehttpserver") { return .pythonHTTPServer }
        if named("rails") { return .rails }
        if named("puma") { return .puma }

        let launcher = names.first ?? program
        if program == "dotnet" || launcher == "dotnet" { return .dotnet }
        if ["bun", "bunx"].contains(program) || ["bun", "bunx"].contains(launcher) { return .bun }
        if program == "deno" || launcher == "deno" { return .deno }
        let nodeTools = ["node", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node", "nodemon"]
        if nodeTools.contains(program) || nodeTools.contains(launcher) { return .node }
        if program == "go" || path.contains("/go-build") { return .go }
        if program == "cargo" || path.contains("/target/debug/") || path.contains("/target/release/") { return .rust }
        if program.hasPrefix("php") { return .php }
        if program.hasPrefix("python") || launcher.hasPrefix("python") { return .python }
        if program == "ruby" || launcher == "ruby" { return .ruby }
        if program == "java" || launcher == "java" { return .java }
        return .other
    }

    // Servers rewrite argv[0] into titles like "next-server (v15.1.0)" or "gunicorn: master [app]".
    private static func programName(_ token: String) -> String {
        func firstWord(_ text: String) -> String { text.split(separator: " ").first.map(String.init) ?? text }
        let word = token.hasPrefix("/")
            ? firstWord((token as NSString).lastPathComponent)
            : (firstWord(token) as NSString).lastPathComponent
        return word.hasSuffix(":") ? String(word.dropLast()) : word
    }
}
