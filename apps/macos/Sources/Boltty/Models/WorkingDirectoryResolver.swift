import Foundation

enum WorkingDirectoryResolver {
  static var homeDirectoryPath: String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }
}
