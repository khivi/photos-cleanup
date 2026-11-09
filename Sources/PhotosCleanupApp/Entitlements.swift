import Security

/// Show in Photos drives Photos with AppleScript, which a sandboxed build can do only with the Apple Events exception for Photos.
let canShowInPhotos: Bool = {
    guard demoDirectory == nil else { return false }
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    func value(_ key: String) -> CFTypeRef? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
    if value("com.apple.security.app-sandbox") as? Bool != true { return true }
    let targets = value("com.apple.security.temporary-exception.apple-events") as? [String]
    return targets?.contains("com.apple.Photos") == true
}()
