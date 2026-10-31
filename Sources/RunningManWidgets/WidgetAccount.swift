import Darwin
import Foundation

enum WidgetAccount {
    static var homeDirectory: URL? {
        // Foundation redirects even homeDirectory(forUser:) to the container
        // for this account. The host publishes outside that container; only
        // its Widgets directory is readable through our sandbox exception.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        return buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let path = account.pw_dir, path.pointee != 0 else { return nil }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
    }
}
