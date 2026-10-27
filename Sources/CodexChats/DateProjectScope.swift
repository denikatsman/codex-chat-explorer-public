import Foundation

enum DateProjectScope: Int, CaseIterable {
    case all, nonProject, project

    var title: String {
        switch self {
        case .all: return "ALL"
        case .nonProject: return "NON-PROJECT"
        case .project: return "PROJECT"
        }
    }
    var description: String {
        switch self {
        case .all: return "All chats"
        case .nonProject: return "Chats with no project"
        case .project: return "Chats assigned to a project"
        }
    }
    func includes(_ chat: Chat) -> Bool {
        switch (self, chat.project.identity) {
        case (.all, _), (.nonProject, .noProject), (.project, .assigned): return true
        default: return false
        }
    }
}
