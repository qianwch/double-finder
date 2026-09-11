import XCTest
@testable import double_finder

/// One command list for toolbar, Settings ▸ Toolbar and the shortcut editor.
@MainActor
final class CommandRegistryTests: XCTestCase {

    func testToolbarCommandsCarryCompleteMetadata() {
        for cmd in AppCommand.toolbarCommands {
            XCTAssertNotNil(cmd.toolbarID, "\(cmd)")
            XCTAssertNotNil(cmd.symbol, "\(cmd)")
            XCTAssertNotNil(cmd.toolbarTooltip, "\(cmd)")
        }
        // Commands without a button must not half-declare one.
        for cmd in AppCommand.allCases where cmd.toolbarID == nil {
            XCTAssertNil(cmd.symbol, "\(cmd)")
            XCTAssertNil(cmd.toolbarTooltip, "\(cmd)")
        }
        let ids = AppCommand.toolbarCommands.map { $0.toolbarID! }
        XCTAssertEqual(Set(ids).count, ids.count, "toolbar ids must be unique")
    }

    func testDefaultToolbarIsExactlyTheBuiltInCommands() {
        // The persisted default layout and the registry describe the same buttons,
        // in the same order — a new command must be added to both on purpose.
        XCTAssertEqual(ToolbarConfig.defaultIDs, AppCommand.toolbarCommands.map { $0.toolbarID! })
    }

    func testChoicesItemsAndBindablesAgree() {
        let choices = CommandRegistry.toolbarChoices
        let items = CommandRegistry.toolbarItems(runBuiltIn: { _ in }, runPlugin: { _ in })
        XCTAssertEqual(choices.map { $0.id }, items.map { $0.id })
        XCTAssertEqual(choices.map { $0.label }, items.map { $0.tooltip })
        XCTAssertTrue(CommandRegistry.bindable.contains(.builtIn(.openTerminal)))
        XCTAssertEqual(AppCommand.openTerminal.defaultHint, "⌘⇧T")
    }

    func testToolbarItemDispatchesThroughRunCommand() {
        var ran: [AppCommand] = []
        let items = CommandRegistry.toolbarItems(runBuiltIn: { ran.append($0) }, runPlugin: { _ in })
        items.first { $0.id == "terminal" }?.action()
        items.first { $0.id == "copy" }?.action()
        XCTAssertEqual(ran, [.openTerminal, .copy])
    }
}
