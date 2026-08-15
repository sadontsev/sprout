import Foundation

/// How one MakerWorld import is going.
///
/// Lives beside `ExploreModel` rather than inside a view because the import outlives the view: it
/// runs in the background, the copy promises browsing continues, and the inspector that started it
/// is unmounted by an inspector toggle or a section change.
enum MakerWorldImportState {
    case running
    case landed(MakerWorldImportResponse)
    case failed(MWFailure)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
