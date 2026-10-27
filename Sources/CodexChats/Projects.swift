import Foundation

enum ProjectIdentity: Hashable {
    case assigned(kind: String, id: String)
    case noProject
    case unavailable

    var savedKey: String {
        switch self {
        case let .assigned(kind, id): return "\(kind.count):\(kind)\(id)"
        case .noProject: return "no-project"
        case .unavailable: return "projects-unavailable"
        }
    }
    var sortRank: Int {
        switch self { case .assigned: return 0; case .noProject: return 1; case .unavailable: return 2 }
    }
}

struct ProjectReference {
    let identity: ProjectIdentity
    let name: String
    let originalAssignment: Any?
    let originalProject: Any?
}

struct ProjectGroup {
    let project: ProjectReference
    let chats: [Chat]

    static func make(from chats: [Chat]) -> [ProjectGroup] {
        // Chats are already sorted by creation date. Filtering preserves that order.
        Dictionary(grouping: chats, by: { $0.project.identity }).values.map {
            ProjectGroup(project: $0[0].project, chats: $0)
        }.sorted {
            if $0.project.identity.sortRank != $1.project.identity.sortRank {
                return $0.project.identity.sortRank < $1.project.identity.sortRank
            }
            let left = $0.chats.first?.createdAt ?? .distantPast
            let right = $1.chats.first?.createdAt ?? .distantPast
            if left != right { return left > right }
            if $0.project.name != $1.project.name { return $0.project.name < $1.project.name }
            return $0.project.identity.savedKey < $1.project.identity.savedKey
        }
    }
}

struct ProjectCatalog {
    let sourceURL: URL
    private let assignments: [String: Any]
    private let projects: [String: Any]
    private let explicitlyProjectless: Set<String>

    static func load(from url: URL) throws -> ProjectCatalog {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let assignments = root["thread-project-assignments"] as? [String: Any],
              let projects = root["local-projects"] as? [String: Any] else {
            throw StoreError(message: "Project metadata is missing or has an unsupported format.")
        }
        return ProjectCatalog(sourceURL: url, assignments: assignments, projects: projects,
                              explicitlyProjectless: Set(root["projectless-thread-ids"] as? [String] ?? []))
    }

    func project(for chatID: String) -> (ProjectReference, String?) {
        guard let original = assignments[chatID] else {
            return (ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil), nil)
        }
        guard let assignment = original as? [String: Any],
              let kind = assignment["projectKind"] as? String, !kind.isEmpty,
              let id = assignment["projectId"] as? String, !id.isEmpty else {
            return (ProjectReference(identity: .unavailable, name: "Projects unavailable", originalAssignment: original, originalProject: nil),
                    "Malformed project assignment; retained under Projects unavailable.")
        }
        let originalProject = kind == "local" ? projects[id] : nil
        let name = (originalProject as? [String: Any])?["name"] as? String
        let title = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let project = ProjectReference(identity: .assigned(kind: kind, id: id), name: title ?? "Unavailable project (\(id))",
                                       originalAssignment: original, originalProject: originalProject)
        let issue: String?
        if title == nil { issue = "Assigned project name unavailable; recorded project identity retained." }
        else if explicitlyProjectless.contains(chatID) { issue = "Conflicting projectless flag; displaying the recorded project assignment." }
        else { issue = nil }
        return (project, issue)
    }
}
