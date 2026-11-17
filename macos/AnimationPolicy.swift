import Foundation

// Ordering is shared by the actual player and the priority regression checks.
enum AnimationDecision: Equatable {
    case dragging, review, greeting, preview(Int), working, outcome(Int), singing, idle
}

func chooseAnimation(dragging: Bool, pendingReview: Bool, hovered: Bool,
                     greetingCoolingDown: Bool, preview: Int?, working: Bool,
                     outcome: Int?, musicPlaying: Bool) -> AnimationDecision {
    if dragging { return .dragging }
    if pendingReview { return .review }
    if hovered && !greetingCoolingDown { return .greeting }
    if let preview { return .preview(preview) }
    if working { return .working }
    if let outcome { return .outcome(outcome) }
    if musicPlaying { return .singing }
    return .idle
}
