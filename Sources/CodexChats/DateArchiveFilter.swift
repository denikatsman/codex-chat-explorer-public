import Foundation

enum DateArchiveFilter: String, CaseIterable {
    case all, nonArchived, archived

    var title: String {
        switch self {
        case .all: return "ALL"
        case .nonArchived: return "NON-ARCHIVED"
        case .archived: return "ARCHIVED"
        }
    }
    var menuTitle: String {
        switch self {
        case .all: return "All chats"
        case .nonArchived: return "Non-archived only"
        case .archived: return "Archived only"
        }
    }
    func includes(_ chat: Chat) -> Bool {
        if self == .all { return true }
        // Missing/malformed status stays visible in ALL, without inventing a status.
        guard let recorded = chat.original["archived"]?.number, recorded.isFinite else { return false }
        return self == .archived ? recorded != 0 : recorded == 0
    }
}
