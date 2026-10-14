import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

/// The languages offered for translating an image: the name people pick (and the planner writes) and its language.
enum TranslationTargets {
    static let all: [(name: String, identifier: String)] = [
        ("简体中文", "zh-Hans"), ("繁體中文", "zh-Hant"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko"),
        ("Français", "fr"), ("Deutsch", "de"), ("Español", "es"), ("Português", "pt"), ("Italiano", "it"),
        ("العربية", "ar"), ("Русский", "ru"), ("हिन्दी", "hi")
    ]

    /// The language for a target name, also matching names the planner may write in another language ("Chinese", "英文").
    static func language(for name: String) -> Locale.Language? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = all.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return Locale.Language(identifier: match.identifier)
        }
        let aliases: [String: String] = [
            "中文": "zh-Hans", "简体": "zh-Hans", "chinese": "zh-Hans", "simplified chinese": "zh-Hans",
            "繁体中文": "zh-Hant", "繁体": "zh-Hant", "traditional chinese": "zh-Hant",
            "英文": "en", "英语": "en", "日文": "ja", "日语": "ja", "japanese": "ja", "韩文": "ko", "韩语": "ko", "korean": "ko",
            "法语": "fr", "french": "fr", "德语": "de", "german": "de", "西班牙语": "es", "spanish": "es",
            "葡萄牙语": "pt", "portuguese": "pt", "意大利语": "it", "italian": "it", "阿拉伯语": "ar", "arabic": "ar",
            "俄语": "ru", "russian": "ru", "印地语": "hi", "hindi": "hi"
        ]
        return aliases[trimmed.lowercased()].map { Locale.Language(identifier: $0) }
    }
}

enum SystemTranslationError: LocalizedError {
    /// macOS 15 and earlier: no on-device translation API outside SwiftUI.
    case unavailable
    case unknownSourceLanguage
    /// The pair is supported but its languages are not downloaded yet.
    case notInstalled(source: String, target: String)
    case unsupported(source: String, target: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("On-device translation needs macOS 26 or later.", "系统翻译需要 macOS 26 或更高版本。")
        case .unknownSourceLanguage:
            return L("Couldn't tell which language the text is in.", "无法判断图中文字是哪种语言。")
        case .notInstalled(let source, let target):
            return L("On-device translation needs the \(source) and \(target) languages. Download them in System Settings → General → Language & Region → Translation Languages.",
                     "系统翻译需要先下载「\(source)」和「\(target)」语言：系统设置 → 通用 → 语言与地区 → 翻译语言。")
        case .unsupported(let source, let target):
            return L("On-device translation doesn't support \(source) to \(target).", "系统翻译不支持从「\(source)」翻译到「\(target)」。")
        }
    }
}

/// Apple's on-device translation: free, private, and needs no account, once the languages are downloaded.
enum SystemTranslator {
    /// Translates every block from the image's main language. A long block that is clearly in another language
    /// (a Chinese UI quoting English, say) uses its own language when that pair is ready; otherwise it joins the main group.
    /// Only the main pair may ask to download languages. Blocks already in the target language stay as they are.
    static func translate(_ blocks: [RecognizedImageText], to target: Locale.Language) async throws -> [Int: String] {
        guard #available(macOS 26.0, *) else { throw SystemTranslationError.unavailable }
        guard let main = language(of: blocks.map(\.text).joined(separator: "\n")) else {
            throw SystemTranslationError.unknownSourceLanguage
        }
        var result: [Int: String] = [:]
        var mainBlocks: [RecognizedImageText] = []
        var others: [String: (language: Locale.Language, blocks: [RecognizedImageText])] = [:]
        for block in blocks {
            let own = distinctLanguage(of: block.text, besides: main) ?? main
            if sameLanguage(own, target) {
                result[block.id] = block.text
            } else if sameLanguage(own, main) {
                mainBlocks.append(block)
            } else {
                others[own.maximalIdentifier, default: (own, [])].blocks.append(block)
            }
        }
        for (language, group) in others.values {
            if await LanguageAvailability().status(from: language, to: target) == .installed {
                try await translate(group, from: language, to: target, into: &result)
            } else {
                mainBlocks += group
            }
        }
        if !mainBlocks.isEmpty {
            switch await LanguageAvailability().status(from: main, to: target) {
            case .installed: break
            case .supported:
                // Offer the system download prompt, then carry on with the translation.
                guard await SystemTranslationDownload.request(from: main, to: target),
                      await LanguageAvailability().status(from: main, to: target) == .installed else {
                    throw SystemTranslationError.notInstalled(source: name(of: main), target: name(of: target))
                }
            default: throw SystemTranslationError.unsupported(source: name(of: main), target: name(of: target))
            }
            try await translate(mainBlocks, from: main, to: target, into: &result)
        }
        for block in blocks where result[block.id] == nil { result[block.id] = block.text }
        return result
    }

    @available(macOS 26.0, *)
    private static func translate(_ blocks: [RecognizedImageText], from source: Locale.Language, to target: Locale.Language,
                                  into result: inout [Int: String]) async throws {
        let session = TranslationSession(installedSource: source, target: target)
        let requests = blocks.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
            result[id] = response.targetText
        }
    }

    private static func language(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// A block's own language, only when it is long enough and clearly not the image's main language.
    /// Short labels ("Read Docs", "OK") are easily misread, so they always follow the main language.
    private static func distinctLanguage(of text: String, besides main: Locale.Language) -> Locale.Language? {
        guard text.count >= 16 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.9 else { return nil }
        let candidate = Locale.Language(identifier: language.rawValue)
        return sameLanguage(candidate, main) ? nil : candidate
    }

    /// Chinese scripts count as different languages; otherwise the language code decides.
    private static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard a.languageCode?.identifier == "zh" else { return true }
        return (a.script ?? script(of: a)) == (b.script ?? script(of: b))
    }

    private static func script(of language: Locale.Language) -> Locale.Script? {
        language.maximalIdentifier.contains("Hant") ? .hanTraditional : .hanSimplified
    }

    /// In the app's language, not the system's.
    private static func name(of language: Locale.Language) -> String {
        Locale(identifier: L("en", "zh-Hans")).localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}


/// Asks macOS to download translation languages. Only SwiftUI's `translationTask` can show the system's download
/// prompt, so a zero-size SwiftUI view is attached to the front window for the duration.
@MainActor
enum SystemTranslationDownload {
    /// Shows the system prompt; true once the languages are downloaded.
    static func request(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        guard #available(macOS 15.0, *), let host = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return false }
        return await withCheckedContinuation { continuation in
            var hosting: NSView?
            var finished = false
            let view = TranslationDownloadView(configuration: .init(source: source, target: target)) { ok in
                guard !finished else { return }
                finished = true
                hosting?.removeFromSuperview()
                continuation.resume(returning: ok)
            }
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            host.addSubview(hostingView)
            hosting = hostingView
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationDownloadView: View {
    let configuration: TranslationSession.Configuration
    let done: @MainActor (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    done(true)
                } catch {
                    log("translation language download failed", error: error)
                    done(false)
                }
            }
    }
}
