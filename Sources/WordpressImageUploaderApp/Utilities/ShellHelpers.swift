import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let supportedImageExtensions: Set<String> = [
    "jpg", "jpeg", "jpe", "gif", "png", "bmp", "ico", "webp", "avif", "heic", "pdf"
]

func shellSingleQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}


func ensureNoTrailingSlash(_ value: String) -> String {
    var result = value
    while result.count > 1, result.hasSuffix("/") {
        result = String(result.dropLast())
    }
    return result
}

func isSupportedImageExtension(_ url: URL) -> Bool {
    supportedImageExtensions.contains(url.pathExtension.lowercased())
}

// AVIF sideloading is JPEG-only, matching the server plugin's mime gate.
func isJpegSourceExtension(_ url: URL) -> Bool {
    ["jpg", "jpeg", "jpe"].contains(url.pathExtension.lowercased())
}

// Prefix a `wp` command with a PHP finder so WP-CLI uses the correct PHP binary
// even on servers where only versioned names (php8.1, php8.2, …) exist in PATH.
// WP-CLI honours WP_CLI_PHP; if none is found the var is empty and WP-CLI falls
// back to its own detection — no regression on well-configured servers.
// Versioned names are checked first so a broken /usr/bin/php symlink (e.g. from
// CyberPanel overwriting it) does not shadow a working php8.x binary.
private let wpCliPhpFinder = "WP_CLI_PHP=$(command -v php8.4 php8.3 php8.2 php8.1 php8.0 php84 php83 php82 php81 php80 php 2>/dev/null | head -1)"

func wpCommand(_ command: String) -> String {
    "export \(wpCliPhpFinder); \(command)"
}

/// Extracts the outermost {...} span from noisy command output. wp-cli JSON
/// arrives wrapped in PHP notices/warnings on some hosts (display_errors,
/// open_basedir); this recovers the object without trusting line structure.
func extractJSONObject(from rawOutput: String) -> Data? {
    guard let jsonStart = rawOutput.firstIndex(of: "{"),
          let jsonEnd = rawOutput.lastIndex(of: "}"),
          jsonStart < jsonEnd
    else {
        return nil
    }
    return Data(rawOutput[jsonStart...jsonEnd].utf8)
}

func parseRsyncProgress(_ line: String) -> Double? {
    guard let percentRange = line.range(of: #"\d{1,3}%"#, options: .regularExpression) else {
        return nil
    }

    let number = line[percentRange].replacingOccurrences(of: "%", with: "")
    guard let value = Double(number) else { return nil }
    return min(max(value / 100.0, 0.0), 1.0)
}
