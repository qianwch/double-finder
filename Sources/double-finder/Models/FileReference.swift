import Foundation

/// A file namespace, independent of panel navigation and connection lifetime.
/// A backend with multiple containers should give each container its own ID.
enum FileEndpointID: Hashable, Sendable {
    case local
    case remote(String)
}

/// A backend path is only unique within its endpoint. Preserve its exact spelling:
/// remote keys and virtual archive paths do not obey local path normalization.
struct FileReference: Hashable, Sendable {
    let endpointID: FileEndpointID
    let path: String
}
