import AppKit

// 纯菜单栏应用入口。
//
// 不用 SwiftUI App 生命周期：MenuBarExtra 会把菜单栏 label 强制渲染成单色模板图片，
// mood 颜色会丢失（看起来就是黑点/白点）。改由 AppDelegate 用 AppKit 的
// NSStatusItem 自绘非模板彩色图标（见 AppDelegate.setupStatusItem）。
@main
enum DSHPetMain {
    @MainActor
    static func main() {
        DSHPetMigration.migrateUserDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
