//
//  AppInfo.swift
//  Bitarf RI
//
//  Single source of truth for the user-visible version / build number.
//  Per project convention the build number is bumped on *every* product change.
//

import Foundation

public enum AppInfo {

    /// Marketing version.
    public static let version = "0.3.0"

    /// Build number. Bump by 1–10 on every product-affecting change.
    public static let build = 395

    /// e.g. "0.3.0 (45)"
    public static var versionString: String {
        "\(version) (\(build))"
    }
}
