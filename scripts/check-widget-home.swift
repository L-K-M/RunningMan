import Foundation

@main
struct WidgetHomeCheck {
    static func main() {
        // Capture the expected account home before the test app is sandboxed.
        guard CommandLine.arguments.count == 2 else {
            print(FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }

        let expected = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard FileManager.default.homeDirectoryForCurrentUser != expected else {
            fail("The widget home check did not enter App Sandbox.")
        }
        guard WidgetAccount.homeDirectory == expected else {
            fail("The widget resolved its container instead of the account home.")
        }
        print("The sandboxed widget resolves the account home correctly.")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
