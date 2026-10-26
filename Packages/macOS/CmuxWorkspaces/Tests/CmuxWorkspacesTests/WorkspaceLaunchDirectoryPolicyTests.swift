import Foundation
import Testing
@testable import CmuxWorkspaces

struct WorkspaceLaunchDirectoryPolicyTests {
    @Test func configuredFolderReplacesInheritedRepoOnlyForFreshShells() {
        let id = UUID()
        let policy = WorkspaceLaunchDirectoryPolicy()
        let roots = [id.uuidString: "/products/lightwell"]
        #expect(policy.resolve(workspaceID: id, explicit: nil, configured: roots, isRemote: false, hasStartupWork: false, directoryExists: { _ in true }) == "/products/lightwell")
        #expect(policy.resolve(workspaceID: id, explicit: "/products/lightwell/app", configured: roots, isRemote: false, hasStartupWork: false, directoryExists: { _ in true }) == "/products/lightwell/app")
        #expect(policy.resolve(workspaceID: id, explicit: nil, configured: roots, isRemote: true, hasStartupWork: false, directoryExists: { _ in true }) == nil)
        #expect(policy.resolve(workspaceID: id, explicit: nil, configured: roots, isRemote: false, hasStartupWork: true, directoryExists: { _ in true }) == nil)
    }
    @Test func unrelatedMissingAndRelativeFoldersDoNotRedirectLaunches() {
        let id = UUID()
        let policy = WorkspaceLaunchDirectoryPolicy()
        for roots in [[UUID().uuidString: "/other"], [id.uuidString: "relative"], [id.uuidString: ""]] {
            #expect(policy.resolve(workspaceID: id, explicit: nil, configured: roots, isRemote: false, hasStartupWork: false, directoryExists: { _ in true }) == nil)
        }
        #expect(policy.resolve(workspaceID: id, explicit: nil, configured: [id.uuidString: "/missing"], isRemote: false, hasStartupWork: false, directoryExists: { _ in false }) == nil)
    }
}
