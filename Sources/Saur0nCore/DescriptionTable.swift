// SPDX-License-Identifier: GPL-3.0-or-later
/// Plain descriptions, in our own words, for Apple processes the user sees near the top of the
/// list that have no man page on the Mac. They win over a man page, so a weak page line ("airport
/// daemon") is fixed by adding the process here. Nothing in this table is copied from Apple text.
enum DescriptionTable {
    static let byName: [String: String] = [
        "kernel_task": "the macOS kernel",
        "mds_stores": "Spotlight: keeps the search index",
        "mdworker_shared": "Spotlight: reads files to index them",
        "corespotlightd": "Spotlight: indexes content apps hand to it",
        "fseventsd": "records file changes for Spotlight, Time Machine and other watchers",
        "tccd": "privacy permissions: camera, microphone, files, screen",
        "bluetoothd": "Bluetooth",
        "loginwindow": "the login window and the logged-in session",
        "com.apple.WebKit.WebContent": "a web page (Safari or an app's web view)",
        "com.apple.WebKit.GPU": "web page graphics and media",
        "com.apple.WebKit.Networking": "web page network traffic",
        "mediaanalysisd": "analyses photos and videos (faces, scenes, text)",
        "photoanalysisd": "Photos library analysis (people, memories)",
        "com.apple.geod": "maps and location data",
        "com.apple.Virtualization.VirtualMachine": "a virtual machine",
    ]
}
