import Foundation

enum RelayPage: Int, CaseIterable {
    case direction, files, destination, review, progress, success, recovery

    var isSetup: Bool { rawValue <= RelayPage.review.rawValue }
    var stepNumber: Int { isSetup ? rawValue + 1 : 4 }
    var title: String {
        switch self {
        case .direction: "Direction"
        case .files: "Files"
        case .destination: "Destination"
        case .review: "Review"
        case .progress: "Transfer"
        case .success: "Complete"
        case .recovery: "Recovery"
        }
    }
}
