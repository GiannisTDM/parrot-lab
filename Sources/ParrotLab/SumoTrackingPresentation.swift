import AppKit

enum SumoTrackingPresentationState: Equatable {
    case idle, tracking, following, recovering, lost

    var title: String {
        switch self {
        case .idle: return "Choose a subject"
        case .tracking: return "Tracking"
        case .following: return "Following"
        case .recovering: return "Recovering"
        case .lost: return "Lost"
        }
    }

    var color: NSColor {
        switch self {
        case .idle: return .secondaryLabelColor
        case .tracking: return .systemCyan
        case .following: return .systemGreen
        case .recovering: return .systemOrange
        case .lost: return .systemRed
        }
    }
}
