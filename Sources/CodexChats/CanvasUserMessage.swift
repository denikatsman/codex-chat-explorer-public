import Foundation

/// A replaceable reading projection. Never changes RecordedMessage or source bytes.
struct CanvasUserPresentation {
    struct Quote {
        let label: String
        let text: String
        var comment: String? = nil
        var source: String? = nil
    }
    struct File {
        let name: String
        let path: String
        let image: Bool
    }
    var body: String
    var quotes = [Quote]()
    var files = [File]()
    var notices = [String]()
    var origin: String? = nil
    var modified = false
}

enum CanvasUserMessage {
    private static let headings = ["Files mentioned by the user", "Files pasted by the user", "Response annotations", "Context from my IDE setup", "In app browser", "Chrome tabs", "Applications mentioned by the user", "Selected text", "Page context"]
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern:pattern))?.matches(in:text,range:NSRange(location:0,length:(text as NSString).length)) ?? []
    }
    private static func inner(_ tag: String, _ text: String) -> String? {
        guard let match = matches("(?s)<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>",text).first else { return nil }
        return (text as NSString).substring(with:match.range(at:1))
    }
    /// Mask code and known serialized blocks without moving UTF-16 offsets.
    private static func structural(_ text: String) -> String {
        let result = NSMutableString(string:text)
        var ranges = [NSRange](), fence: (Character,Int,Int)?
        let source = text as NSString
        var offset = 0
        for line in text.components(separatedBy:"\n") {
            let size = (line as NSString).length, indent = line.prefix { $0 == " " }.count
            let trimmed = line.dropFirst(indent)
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if let active = fence {
                    if marker == active.0, count >= active.1, trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                        ranges.append(NSRange(location:active.2,length:offset+size-active.2)); fence = nil
                    }
                } else if count >= 3 { fence = (marker,count,offset) }
            }
            offset += size+1
        }
        if let active = fence { ranges.append(NSRange(location:active.2,length:source.length-active.2)) }
        for tag in ["appshot","in-app-browser-context","response-annotations"] {
            ranges += matches("(?s)<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>",text).map(\.range)
        }
        for range in ranges {
            let masked = source.substring(with:range).utf16.map { $0 == 10 || $0 == 13 ? $0 : UInt16(32) }
            result.replaceCharacters(in:range,with:String(decoding:masked,as:UTF16.self))
        }
        return result as String
    }

    static func project(_ text: String) -> CanvasUserPresentation {
        var result = CanvasUserPresentation(body:text)
        guard text.utf8.count <= 2 * 1024 * 1024 else { return result }
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if trimmed.hasPrefix("<send_user_message_question_reply>"), let value = inner("send_user_message_question_reply",trimmed),
           let data = value.data(using:.utf8), let replies = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]],
           replies.allSatisfy({ $0["questionItemId"] is String && $0["answer"] != nil }) {
            result.body = suffix(after:"send_user_message_question_reply",in:trimmed); result.modified = true
            for reply in replies {
                let question = reply["question"] as? String ?? ""
                let answer: String
                if let value = reply["answer"] as? String { answer = value }
                else if let values = reply["answer"] as? [String] { answer = values.joined(separator:"\n") }
                else { result.notices.append("An answer has an unsupported format. Open the original chat to inspect it."); continue }
                result.quotes.append(.init(label:"Question",text:question,comment:answer))
            }
            return result
        }
        if trimmed.hasPrefix("<send_user_message_question_reply>"), trimmed.contains("questionItemId") {
            result.body = suffix(after:"send_user_message_question_reply",in:trimmed); result.modified = true
            result.notices.append("A question reply could not be displayed. Open the original chat to inspect it."); return result
        }
        if trimmed.hasPrefix("<realtime_delegation>"), inner("transcript_delta",trimmed) != nil, let input = inner("input",trimmed) {
            result.body = input.trimmingCharacters(in:.whitespacesAndNewlines); result.origin = "VOICE REQUEST"; result.modified = true; return result
        }
        if trimmed.hasPrefix("<heartbeat>"), inner("automation_id",trimmed) != nil, inner("current_time_iso",trimmed) != nil, let instructions = inner("instructions",trimmed) {
            result.body = instructions.trimmingCharacters(in:.whitespacesAndNewlines); result.origin = "SCHEDULED TASK"; result.modified = true; return result
        }
        let known = headings.contains { trimmed.hasPrefix("# \($0):") }
            || trimmed.hasPrefix("<in-app-browser-context source=\"ambient-ui-state\">")
        guard known else { return result }
        let masked = structural(text)
        guard let separator = matches(#"(?m)^## My request(?: for Codex)?:[ \t]*\r?$"#,masked).first else { return result }
        let source = text as NSString
        let prefix = source.substring(to:separator.range.location)
        var start = NSMaxRange(separator.range)
        if start < source.length, source.character(at:start) == 13 { start += 1 }
        if start < source.length, source.character(at:start) == 10 { start += 1 }
        result.body = source.substring(from:start); result.modified = true

        if let annotations = inner("response-annotations",prefix) {
            if let data = annotations.data(using:.utf8), let items = try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] {
                for item in items.prefix(128) {
                    guard let quote = item["text"] as? String else { result.notices.append("A quoted selection is unavailable."); continue }
                    let source = (item["source"] as? [String:Any]).flatMap { try? JSONSerialization.data(withJSONObject:$0,options:.sortedKeys) }.flatMap { String(data:$0,encoding:.utf8) }
                    result.quotes.append(.init(label:"Quoted reply",text:quote,comment:item["annotation"] as? String,source:source))
                }
                if items.count > 128 { result.notices.append("Additional annotations remain available in the original chat.") }
            } else { result.notices.append("Annotation data could not be displayed. Open the original chat to inspect it.") }
        }

        let structure = structural(prefix) as NSString
        let sections = matches(#"(?m)^# ([^\r\n]+):[ \t]*\r?$"#,structure as String).filter { headings.contains(structure.substring(with:$0.range(at:1))) }
        for (index,section) in sections.enumerated() {
            let title = structure.substring(with:section.range(at:1))
            let end = index+1 < sections.count ? sections[index+1].range.location : structure.length
            let range = NSRange(location:NSMaxRange(section.range),length:end-NSMaxRange(section.range))
            let content = (prefix as NSString).substring(with:range)
            switch title {
            case "Files mentioned by the user", "Files pasted by the user":
                let refs = matches(#"(?m)^## (.+?): ((?:/|~/)[^\r\n]+)\r?$"#,content)
                for ref in refs {
                    let string = content as NSString
                    let name = string.substring(with:ref.range(at:1)), path = string.substring(with:ref.range(at:2))
                    let rest = string.substring(from:NSMaxRange(ref.range)).trimmingCharacters(in:.whitespacesAndNewlines)
                    result.files.append(.init(name:name,path:path,image:rest.hasPrefix("Image attachment: true")))
                }
            case "Selected text":
                let selections = matches(#"(?m)^## Selection [0-9]+[^\r\n]*\r?$"#,structural(content))
                for (index,selection) in selections.enumerated() {
                    let end = index+1 < selections.count ? selections[index+1].range.location : (content as NSString).length
                    let range = NSRange(location:NSMaxRange(selection.range),length:end-NSMaxRange(selection.range))
                    result.quotes.append(.init(label:"Selected text",text:(content as NSString).substring(with:range).trimmingCharacters(in:.newlines)))
                }
            case "Context from my IDE setup":
                let code = matches(#"(?ms)^## Active selection of the file:[ \t]*\r?\n(.*?)(?=^## (?:Open tabs|Active file):|\z)"#,structural(content))
                for selection in code { result.quotes.append(.init(label:"Selected code",text:(content as NSString).substring(with:selection.range(at:1)).trimmingCharacters(in:.newlines))) }
            default: break // Browser/tab/IDE/app/Page context is ambient, not authored prose.
            }
        }
        return result
    }
    private static func suffix(after tag: String, in text: String) -> String {
        guard let range = text.range(of:"</\(tag)>") else { return "" }
        return String(text[range.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
