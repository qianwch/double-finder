import Foundation

/// The one list every command surface draws from — toolbar buttons, Settings ▸
/// Toolbar's choices, the shortcut editor and key dispatch. Built-in commands
/// are `AppCommand` (which carries label / default key / toolbar id / symbol);
/// plugin commands come from `PluginManager` under "plugin.<plugin>/<cmd>" ids.
/// Adding a built-in command = one `AppCommand` case (plus its `runCommand`
/// branch); nothing else has to be listed by hand.
@MainActor
enum CommandRegistry {
    /// Toolbar id prefix of plugin commands.
    static let pluginToolbarPrefix = "plugin."

    /// What the toolbar can show: (button id, English tooltip / label).
    static var toolbarChoices: [(id: String, label: String)] {
        AppCommand.toolbarCommands.map { ($0.toolbarID!, $0.toolbarTooltip!) }
            + PluginManager.shared.commands.map { ($0.toolbarID, $0.extensionObject.title) }
    }

    /// Toolbar items for every command (built-in + plugin), each wired to its
    /// action through the two dispatch closures; `ToolbarConfig.ids` then
    /// selects and orders them.
    static func toolbarItems(runBuiltIn: @escaping (AppCommand) -> Void,
                             runPlugin: @escaping (String) -> Void) -> [ToolbarBar.Item] {
        let builtIn = AppCommand.toolbarCommands.map { cmd in
            ToolbarBar.Item(id: cmd.toolbarID!, symbol: cmd.symbol!, tooltip: cmd.toolbarTooltip!) {
                runBuiltIn(cmd)
            }
        }
        let plugins = PluginManager.shared.commands.map { reg in
            let id = reg.id
            return ToolbarBar.Item(id: reg.toolbarID, symbol: reg.extensionObject.symbolName,
                                   tooltip: reg.extensionObject.title) { runPlugin(id) }
        }
        return builtIn + plugins
    }

    /// Everything a shortcut can be bound to.
    static var bindable: [BindableCommand] {
        AppCommand.allCases.map { .builtIn($0) }
            + PluginManager.shared.commands.map { .plugin(id: $0.id, title: $0.extensionObject.title) }
    }
}
