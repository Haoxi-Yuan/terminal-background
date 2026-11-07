// terminal_background: sets the background of every Terminal window (and new ones)
// to a solid color or an image, keeping the text readable.
//
// Usage:
//   terminal_background                      asks for a color or an image path
//   terminal_background '#1E2030'            solid color (#RGB or #RRGGBB, '#' optional)
//   terminal_background ~/Pictures/photo.jpg image (a path dragged into Terminal works too)
//   terminal_background reset                back to the profile used before
//
// Readability: the text color must keep at least 7:1 contrast with the background
// (WCAG AAA). A color that is too light is darkened, keeping its hue. An image gets a
// dark overlay just strong enough for 98% of its pixels to reach 7:1 (at least 35%).
//
// How it works: Terminal's scripting interface cannot set background images or opacity,
// so the tool writes a profile file based on the original profile, imports it (Terminal
// opens a window for an imported profile, which is closed right away), makes it the
// default and startup profile, applies it to every tab, and deletes the previous one.
// Terminal stretches background images to the window, so images are center-cropped to
// the typical shape of the open windows, darkened, and saved as a copy under
// ~/Library/Application Support/terminal_background.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let profilePrefix = "Custom Background"
let minContrast = 7.0        // WCAG AAA for normal text
let imageCoverage = 0.98     // share of image pixels that must reach minContrast
let minDim = 0.35            // overlay opacity range for images
let maxDim = 0.95
let maxImageSide = 2560
let titleBarHeight = 28.0
let fallbackBaseProfile = "Clear Dark"

let fileManager = FileManager.default
let supportDir = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/terminal_background")
let baseNameFile = supportDir.appendingPathComponent("base-profile.txt")

struct Failure: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("terminal_background: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Colors

struct RGB {
    var r, g, b: Double
    static func * (c: RGB, k: Double) -> RGB { RGB(r: c.r * k, g: c.g * k, b: c.b * k) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
    /// Rounded down to 8 bits so rounding never makes a darkened color lighter.
    var quantizedDown: RGB {
        RGB(r: floor(r * 255) / 255, g: floor(g * 255) / 255, b: floor(b * 255) / 255)
    }
}

func parseHex(_ text: String) -> RGB? {
    var h = text.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 3 || h.count == 6, h.allSatisfy(\.isHexDigit) else { return nil }
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = Int(h, radix: 16)!
    return RGB(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
}

func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func luminance(_ c: RGB) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

/// The color scaled down (same hue) until light text on it reaches minContrast.
func darkenedForText(_ color: RGB, textLuminance: Double) -> RGB {
    if contrast(luminance(color), textLuminance) >= minContrast { return color }
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 {
        let k = (lo + hi) / 2
        if contrast(luminance(color * k), textLuminance) >= minContrast { lo = k } else { hi = k }
    }
    return (color * lo).quantizedDown
}

/// Terminal only accepts colors archived the way it writes them: calibrated (Generic) RGB.
func terminalColorData(_ c: RGB, alpha: Double = 1) -> Data {
    let generic = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha).usingColorSpace(.genericRGB)!
    let color = NSColor(calibratedRed: generic.redComponent, green: generic.greenComponent,
                        blue: generic.blueComponent, alpha: generic.alphaComponent)
    return try! NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
}

func decodeTerminalColor(_ value: Any?) -> RGB? {
    guard let data = value as? Data,
          let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
          let s = color.usingColorSpace(.sRGB)
    else { return nil }
    return RGB(r: s.redComponent, g: s.greenComponent, b: s.blueComponent)
}

// MARK: - Terminal scripting

func run(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure(message: String(decoding: errors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
func terminal(_ lines: [String]) throws -> String {
    let script = ["tell application \"Terminal\""] + lines + ["end tell"]
    return try run("/usr/bin/osascript", script.flatMap { ["-e", $0] })
}

func visibleWindowIDs() throws -> Set<Int> {
    let out = try terminal(["get id of every window whose visible is true"])
    return Set(out.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
}

/// Width/height of the content area of the open windows (median), used to crop images.
func typicalWindowAspect() -> Double {
    guard let out = try? terminal(["get bounds of every window whose visible is true"]) else { return 1.6 }
    let n = out.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    var aspects: [Double] = []
    var i = 0
    while i + 3 < n.count {
        let w = n[i + 2] - n[i], h = n[i + 3] - n[i + 1] - titleBarHeight
        if w > 0, h > 0 { aspects.append(w / h) }
        i += 4
    }
    guard !aspects.isEmpty else { return 1.6 }
    return aspects.sorted()[aspects.count / 2]
}

func applyToAllTabs(_ settingsName: String) -> [String] {
    [
        "set chosen to settings set \(quoted(settingsName))",
        "set default settings to chosen",
        "set startup settings to chosen",
        "repeat with w in windows",
        "repeat with t in tabs of w",
        "set current settings of t to chosen",
        "end repeat",
        "end repeat",
    ]
}

func deleteCustomProfiles(except keep: String?) throws {
    try terminal([
        "repeat with n in (get name of every settings set)",
        "set n to contents of n",
        "if n starts with \(quoted(profilePrefix)) and n is not \(quoted(keep ?? "")) then delete settings set n",
        "end repeat",
    ])
}

// MARK: - Profiles

func baseProfileName() throws -> String {
    if let saved = try? String(contentsOf: baseNameFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
        return saved
    }
    let current = try terminal(["get name of default settings"])
    let name = current.hasPrefix(profilePrefix) ? fallbackBaseProfile : current
    try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try name.write(to: baseNameFile, atomically: true, encoding: .utf8)
    return name
}

func baseProfile(named name: String) throws -> [String: Any] {
    if let all = CFPreferencesCopyAppValue("Window Settings" as CFString, "com.apple.Terminal" as CFString)
        as? [String: Any], let profile = all[name] as? [String: Any] {
        return profile
    }
    // Built-in profiles that were never edited are not in the preferences yet.
    let builtIn = URL(fileURLWithPath:
        "/System/Applications/Utilities/Terminal.app/Contents/Resources/Initial Settings/\(name).terminal")
    guard let data = try? Data(contentsOf: builtIn),
          let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { throw Failure(message: "cannot read the Terminal profile \"\(name)\"") }
    return profile
}

/// Imports the profile, applies it everywhere, and removes the previous custom profile.
func install(_ profile: [String: Any]) throws {
    try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let file = supportDir.appendingPathComponent("\(profilePrefix).terminal")
    try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: file)

    let before = try visibleWindowIDs()
    _ = try run("/usr/bin/open", ["-g", "-a", "Terminal", file.path])
    var importWindow: Int?
    for _ in 0..<60 {
        usleep(100_000)
        if let id = try visibleWindowIDs().subtracting(before).first {
            importWindow = id
            break
        }
    }
    guard let importWindow else {
        throw Failure(message: "Terminal did not import the profile. If it shows an alert, close it and try again.")
    }
    let imported = try terminal(["get name of current settings of window id \(importWindow)"])
    try terminal(applyToAllTabs(imported))
    try deleteCustomProfiles(except: imported)
    closeImportWindow(importWindow)
}

/// Closes the window Terminal opened for the import. Terminal refuses (and asks for
/// confirmation) while the new shell is still starting up, so wait until it is idle.
func closeImportWindow(_ id: Int) {
    for _ in 0..<150 {
        if (try? terminal(["get busy of tab 1 of window id \(id)"])) == "false" { break }
        usleep(100_000)
    }
    usleep(200_000)
    _ = try? terminal(["close window id \(id)"])
    for _ in 0..<20 {
        if (try? visibleWindowIDs().contains(id)) == false { return }
        usleep(100_000)
    }
    print("Note: please close the extra Terminal window that opened during the import.")
}

func removeGeneratedImages(except keep: URL?) {
    let files = (try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
    for f in files where f.lastPathComponent.hasPrefix("background-") && f.standardizedFileURL != keep?.standardizedFileURL {
        try? fileManager.removeItem(at: f)
    }
}

/// The base profile with readable light text (in case the base uses dark text).
func preparedProfile(baseName: String) throws -> (profile: [String: Any], textLuminance: Double, text: RGB) {
    var profile = try baseProfile(named: baseName)
    var text = decodeTerminalColor(profile["TextColor"]) ?? RGB(r: 0, g: 0, b: 0)
    if luminance(text) < 0.5 {
        text = RGB(r: 0.9, g: 0.9, b: 0.9)
        profile["TextColor"] = terminalColorData(text)
        profile["TextBoldColor"] = terminalColorData(RGB(r: 0.94, g: 0.94, b: 0.94))
    }
    profile["name"] = profilePrefix
    profile["type"] = "Window Settings"
    profile["BackgroundBlur"] = 0.0
    profile["BackgroundSettingsForInactiveWindows"] = false
    profile.removeValue(forKey: "BackgroundImageBookmark")
    profile.removeValue(forKey: "BackgroundImagePath")
    return (profile, luminance(text), text)
}

// MARK: - Images

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,  // honor photo orientation
        kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func centerCrop(_ image: CGImage, aspect: Double) -> CGImage {
    let w = Double(image.width), h = Double(image.height)
    let rect = w / h > aspect
        ? CGRect(x: (w - h * aspect) / 2, y: 0, width: h * aspect, height: h)
        : CGRect(x: 0, y: (h - w / aspect) / 2, width: w, height: w / aspect)
    return image.cropping(to: rect.integral) ?? image
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws the image over black, then a black layer of the given opacity.
func darkened(_ image: CGImage, dim: Double, maxSide: Int? = nil) -> CGImage {
    var w = image.width, h = image.height
    if let maxSide, max(w, h) > maxSide {
        let s = Double(maxSide) / Double(max(w, h))
        w = max(1, Int(Double(w) * s))
        h = max(1, Int(Double(h) * s))
    }
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    if dim > 0 {
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dim))
        ctx.fill(rect)
    }
    return ctx.makeImage()!
}

func pixels(_ image: CGImage) -> [RGB] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    return (0..<(image.width * image.height)).map {
        RGB(r: Double(bytes[$0 * 4]) / 255, g: Double(bytes[$0 * 4 + 1]) / 255, b: Double(bytes[$0 * 4 + 2]) / 255)
    }
}

/// Smallest black overlay opacity that lets imageCoverage of the pixels reach minContrast.
/// Measured on real renders of a small copy, because Core Graphics' blending does not
/// match a simple per-channel formula.
func overlayOpacity(for small: CGImage, textLuminance: Double) -> (dim: Double, average: RGB) {
    var dim = minDim
    while true {
        let px = pixels(darkened(small, dim: dim))
        let readable = px.reduce(0) { $0 + (contrast(luminance($1), textLuminance) >= minContrast ? 1 : 0) }
        if Double(readable) / Double(px.count) >= imageCoverage || dim >= maxDim {
            let n = Double(px.count)
            let average = RGB(r: px.reduce(0) { $0 + $1.r } / n, g: px.reduce(0) { $0 + $1.g } / n,
                              b: px.reduce(0) { $0 + $1.b } / n)
            return (dim, average)
        }
        dim = min(maxDim, dim + 0.01)
    }
}

func savePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(message: "cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure(message: "cannot write \(url.path)") }
}

// MARK: - Commands

func setColor(_ color: RGB) throws {
    let baseName = try baseProfileName()
    var (profile, textLuminance, text) = try preparedProfile(baseName: baseName)
    let final = darkenedForText(color, textLuminance: textLuminance)
    profile["BackgroundColor"] = terminalColorData(final)
    try install(profile)
    removeGeneratedImages(except: nil)
    let ratio = contrast(luminance(final), textLuminance)
    if final.hex == color.hex {
        print("Background set to \(final.hex) in all Terminal windows (text contrast \(String(format: "%.1f", ratio)):1).")
    } else {
        print("\(color.hex) is too light for the text (\(text.hex)); darkened to \(final.hex) "
            + "(text contrast \(String(format: "%.1f", ratio)):1). Applied to all Terminal windows.")
    }
}

func setImage(_ url: URL) throws {
    guard let original = loadImage(url) else { throw Failure(message: "cannot read an image from \(url.path)") }
    let baseName = try baseProfileName()
    var (profile, textLuminance, _) = try preparedProfile(baseName: baseName)

    let aspect = typicalWindowAspect()
    let cropped = centerCrop(original, aspect: aspect)
    let small = darkened(cropped, dim: 0, maxSide: 160)
    let (dim, average) = overlayOpacity(for: small, textLuminance: textLuminance)
    let final = darkened(cropped, dim: dim)

    try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    let saved = supportDir.appendingPathComponent("background-\(stamp).png")
    try savePNG(final, to: saved)

    // Average of the darkened image, shown while a window is being resized.
    profile["BackgroundColor"] = terminalColorData(average)
    profile["BackgroundImageBookmark"] = try NSKeyedArchiver.archivedData(
        withRootObject: try saved.bookmarkData(), requiringSecureCoding: false)
    profile["BackgroundImagePath"] = saved.path

    try install(profile)
    removeGeneratedImages(except: saved)
    print("Background set to \(url.lastPathComponent) in all Terminal windows "
        + "(cropped to \(String(format: "%.2f", aspect)):1, dark overlay \(Int(round(dim * 100)))%).")
}

func reset() throws {
    let baseName = (try? String(contentsOf: baseNameFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBaseProfile
    try terminal(applyToAllTabs(baseName))
    try deleteCustomProfiles(except: nil)
    removeGeneratedImages(except: nil)
    try? fileManager.removeItem(at: supportDir.appendingPathComponent("\(profilePrefix).terminal"))
    try? fileManager.removeItem(at: baseNameFile)
    print("All Terminal windows are back to \"\(baseName)\".")
}

/// Accepts a path typed, quoted, or dragged into Terminal (which escapes spaces).
func cleanedPath(_ input: String) -> String {
    var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count >= 2, let first = t.first, first == t.last, first == "'" || first == "\"" {
        t = String(t.dropFirst().dropLast())
    } else {
        var out = "", escaped = false
        for ch in t {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        t = out
    }
    return (t as NSString).expandingTildeInPath
}

let usage = """
    Usage: terminal_background [COLOR | IMAGE | reset]
      COLOR  hex color such as #1E2030 or 1e2030 (too light colors are darkened for readable text)
      IMAGE  path to an image (gets a dark overlay for readable text)
      reset  go back to the original Terminal profile
    Without an argument it asks for a color or an image path.
    """

var input = CommandLine.arguments.dropFirst().joined(separator: " ")
if input.isEmpty {
    print("Enter a HEX color (e.g. #1E2030) or an image path (you can drag an image here):")
    print("> ", terminator: "")
    guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { exit(0) }
    input = line
}
let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

do {
    switch trimmed.lowercased() {
    case "-h", "--help", "help":
        print(usage)
    case "reset", "--reset":
        try reset()
    default:
        let path = cleanedPath(trimmed)
        if let color = parseHex(trimmed), !fileManager.fileExists(atPath: path) {
            try setColor(color)
        } else if fileManager.fileExists(atPath: path) {
            try setImage(URL(fileURLWithPath: path))
        } else {
            fail("\"\(trimmed)\" is neither a hex color nor an existing image file.\n\n\(usage)")
        }
    }
} catch let error as Failure {
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}
