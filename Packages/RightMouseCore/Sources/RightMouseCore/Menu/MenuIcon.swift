import Foundation

/// Presentation-only SF Symbols shared by native menus and their settings preview.
public enum MenuIcon {
    public static func command(_ type: String) -> String {
        switch type {
        case "createFile": return "doc.badge.plus"
        case "copyText": return "doc.on.clipboard"
        case "stageMove": return "scissors"
        case "pasteMove": return "clipboard"
        case "copyTo": return "doc.on.doc"
        case "moveTo": return "arrow.right.doc.on.clipboard"
        case "openFavorite": return "star"
        case "openWith": return "square.grid.2x2"
        default: return "list.bullet"
        }
    }
    public static func template(_ id: String) -> String {
        switch id {
        case "md": return "text.alignleft"
        case "json", "yaml": return "curlybraces"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "sh": return "terminal"
        default: return "doc.text"
        }
    }
    public static func symbol(for entry: MenuEntry) -> String {
        switch entry.action {
        case let .createFile(id, _, _): return template(id)
        case let .copyText(format):
            switch format {
            case .path: return "link"
            case .name: return "textformat"
            case .stem: return "textformat.abc"
            case .shellPath: return "terminal"
            }
        case .stageMove: return "scissors"
        case .pasteMove: return "clipboard"
        case let .transfer(mode, _, _): return mode == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard"
        case .openFavorite: return "folder"
        case let .openWith(id, _): return id == "terminal" ? "terminal" : "app"
        case nil:
            if entry.id == "rightmouse" { return "cursorarrow.click.2" }
            if entry.id.hasSuffix(".recent") { return "clock.arrow.circlepath" }
            return command(entry.id)
        }
    }
}
