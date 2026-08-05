import Foundation

/// Pure logic for picking the directory to land in when the user switches to a
/// mounted volume from the drive bar / drive dropdown (TC-style):
///   1. the panel's last visited directory on that volume, if it still exists;
///   2. the other panel's directory, when it sits on the same volume;
///   3. the user's home directory, when the volume is the one holding it;
///   4. the volume's mount point (root) otherwise.
/// `volumeOf` / `isDirectory` are injected so the decision is unit-testable.
enum DriveJump {
    static func destination(volumePath: String,
                            lastPath: String?,
                            otherPanelPath: String?,
                            homePath: String,
                            volumeOf: (String) -> String?,
                            isDirectory: (String) -> Bool) -> String {
        if let last = lastPath, volumeOf(last) == volumePath, isDirectory(last) {
            return last
        }
        if let other = otherPanelPath, volumeOf(other) == volumePath, isDirectory(other) {
            return other
        }
        if volumeOf(homePath) == volumePath, isDirectory(homePath) {
            return homePath
        }
        return volumePath
    }
}
