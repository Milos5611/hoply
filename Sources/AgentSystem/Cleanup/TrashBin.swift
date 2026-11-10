import Foundation

public protocol TrashBin: Sendable {
    func moveToTrash(_ path: String) async throws
}
