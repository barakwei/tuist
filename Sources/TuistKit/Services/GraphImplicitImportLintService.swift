import Foundation
import Path
import Tools
import TuistCore
import TuistLoader
import TuistSupport
import XcodeGraph

final class GraphImplicitImportLintService {
    private let graph: Graph

    init(graph: Graph) {
        self.graph = graph
    }

    func lint() async throws -> [Target: Set<String>] {
        let allTargets = graph
            .projects
            .map(\.value.targets)
            .flatMap { $0 }
            .map(\.value)

        let allTargetNames = Set(allTargets.map(\.productName))

        var implicitTargetImports: [Target: Set<String>] = [:]
        for project in graph.projects.values {
            let allTargets = project.targets.values

            for target in allTargets {
                let targetImports = Set(try await handleTarget(target: target))
                let targetTuistDeclaredDependencies = target.dependencies.compactMap {
                    var dependencyName: String?
                    switch $0 {
                    case let .target(name: targetName, _):
                        dependencyName = project.targets[targetName]?.productName
                    case let .project(target: targetName, path: projectPath, _):
                        dependencyName = graph.projects[projectPath]?.targets[targetName]?.productName
                    default:
                        break
                    }
                    return dependencyName
                }
                var implicitImports: Set<String> = []
                for targetImport in targetImports {
                    if allTargetNames.contains(targetImport), !targetTuistDeclaredDependencies.contains(targetImport) {
                        implicitImports.insert(targetImport)
                    }
                }
                if implicitImports.count > 0 {
                    implicitTargetImports[target] = implicitImports
                }
            }
        }
        return implicitTargetImports
    }

    func handleTarget(target: XcodeGraph.Target) async throws -> Set<String> {
        return try await withThrowingTaskGroup(of: [String].self) { [weak self] group in
            var imports = Set<String>()
            guard let self else { return [] }
            for file in target.sources {
                group.addTask {
                    return try await self.matchPattern(at: file)
                }
            }
            for try await entity in group {
                imports.formUnion(entity)
            }
            return imports
        }
    }

    private func matchPattern(at source: SourceFile) async throws -> [String] {
        var language: ProgrammingLanguage
        switch source.path.url.pathExtension {
        case "swift":
            language = .swift
        case "h", "m", "cpp", "mm":
            language = .objc
        default:
            return []
        }

        let sourceCode = try String(contentsOf: source.path.url)

        return try ImportSourceCodeScanner().extractImports(
            from: sourceCode,
            language: language
        )
    }
}
