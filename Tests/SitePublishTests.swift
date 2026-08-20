import Foundation
import XCTest

/// Site publishing support: GitHub Pages URL derivation, site history
/// records, `git status --porcelain` parsing, and the publish pipeline's
/// short-circuit/failure/resume semantics against real temporary git repos.
@MainActor
final class SitePublishTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-publish-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Pages URL derivation

    func testPagesURLFromSSHCloneWithGitSuffix() {
        let url = SiteProject.pagesURL(forRepository: "git@github.com:vibeforge2014/tivon-support.git")
        XCTAssertEqual(url?.absoluteString, "https://vibeforge2014.github.io/tivon-support/")
    }

    func testPagesURLFromHTTPSWithoutSuffix() {
        let url = SiteProject.pagesURL(forRepository: "https://github.com/vibeforge2014/portal")
        XCTAssertEqual(url?.absoluteString, "https://vibeforge2014.github.io/portal/")
    }

    func testPagesURLForUserPagesRepoMapsToBareHost() {
        let url = SiteProject.pagesURL(forRepository: "git@github.com:vibeforge2014/vibeforge2014.github.io.git")
        XCTAssertEqual(url?.absoluteString, "https://vibeforge2014.github.io")
    }

    func testPagesURLRejectsNonGitHubHosts() {
        XCTAssertNil(SiteProject.pagesURL(forRepository: "https://gitlab.com/root/devops-assistant.git"))
        XCTAssertNil(SiteProject.pagesURL(forRepository: "not a url"))
    }

    func testCustomURLOverridesDerivation() {
        let site = SiteProject(id: "s", name: "S", path: "/tmp/s",
                               repositoryURL: "git@github.com:owner/repo.git",
                               deploy: .gitPushMain,
                               url: "https://custom.example.com")
        XCTAssertEqual(site.liveURL?.absoluteString, "https://custom.example.com")
    }

    func testSiteDecodesLegacyJSONWithoutURLAndRoundTrips() throws {
        let legacy = """
        {"id": "portal", "name": "Portal", "path": "/tmp/portal",
         "repositoryURL": "git@github.com:vibeforge2014/portal.git",
         "deploy": "gh-pages"}
        """
        var site = try JSONDecoder().decode(SiteProject.self, from: Data(legacy.utf8))
        XCTAssertNil(site.url)
        XCTAssertEqual(site.liveURL?.absoluteString, "https://vibeforge2014.github.io/portal/")

        site = SiteProject(id: site.id, name: site.name, path: site.path,
                           repositoryURL: site.repositoryURL, deploy: site.deploy,
                           url: "https://portal.example.com")
        let decoded = try JSONDecoder().decode(
            SiteProject.self, from: JSONEncoder().encode(site))
        XCTAssertEqual(decoded.url, "https://portal.example.com")
    }

    // MARK: - Site history records

    func testSiteRecordFieldsAndLabels() {
        let record = ReleaseRecord(siteName: "Tivon 发布页", siteID: "tivon-support",
                                   commitShortHash: "3f2a1b2", success: true)
        XCTAssertEqual(record.kind, .site)
        XCTAssertEqual(record.platform, "web")
        XCTAssertEqual(record.target, ReleaseRecord.siteDeployTarget)
        XCTAssertEqual(record.versionLabel, "3f2a1b2")
        XCTAssertEqual(record.targetLabel, "站点部署")
        XCTAssertTrue(record.success)
        XCTAssertNil(record.failureStep)
    }

    func testSiteRecordWithoutCommitShowsPlaceholder() {
        let record = ReleaseRecord(siteName: "S", siteID: "s", commitShortHash: nil,
                                   success: false, failureStep: "部署上线")
        XCTAssertEqual(record.versionLabel, "—")
        XCTAssertEqual(record.failureStep, "部署上线")
    }

    func testLegacyAppRecordDecodesAsAppKind() throws {
        let legacy = """
        [{
          "appID": "tivon", "appName": "Tivon", "build": "8", "failureStep": null,
          "id": "\(UUID().uuidString)", "marketing": "1.2.3", "platform": "ios",
          "success": true, "target": "testFlight",
          "timestamp": "2026-08-10T10:00:00Z"
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([ReleaseRecord].self, from: Data(legacy.utf8))
        XCTAssertEqual(records[0].kind, .app)
        XCTAssertEqual(records[0].targetLabel, ReleaseTarget.testFlight.title)
    }

    // MARK: - Status parsing

    func testParseCleanBranchWithAheadBehind() {
        let status = SiteStatusService.parse(
            statusLines: ["## main...origin/main [ahead 1, behind 2]"],
            logLine: "3f2a1b2\u{1f}bump version\u{1f}1770000000")
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.changedFiles, 0)
        XCTAssertTrue(status.isClean)
        XCTAssertFalse(status.hasNothingToPublish)
        XCTAssertEqual(status.lastCommit?.shortHash, "3f2a1b2")
        XCTAssertEqual(status.lastCommit?.subject, "bump version")
    }

    func testParseDirtyWorkingTreeCountsUntracked() {
        let status = SiteStatusService.parse(
            statusLines: [
                "## main...origin/main",
                " M index.html",
                "?? new-page.html",
            ],
            logLine: nil)
        XCTAssertEqual(status.changedFiles, 2)
        XCTAssertFalse(status.isClean)
        XCTAssertTrue(status.hasPendingWork)
        XCTAssertNil(status.lastCommit)
    }

    func testParseDetachedAndFreshRepos() {
        let detached = SiteStatusService.parse(
            statusLines: ["## HEAD (no branch)"], logLine: nil)
        XCTAssertNil(detached.branch)
        XCTAssertNil(detached.upstream)
        XCTAssertFalse(detached.hasUpstream)
        // No upstream → may have unpushed commits → publishable.
        XCTAssertFalse(detached.hasNothingToPublish)

        let fresh = SiteStatusService.parse(
            statusLines: ["## No commits yet on main"], logLine: nil)
        XCTAssertEqual(fresh.branch, "main")
        XCTAssertNil(fresh.upstream)
    }

    func testCleanSyncedTreeHasNothingToPublish() {
        let status = SiteStatusService.parse(
            statusLines: ["## main...origin/main"], logLine: "abc1234\tinit\t1770000000")
        XCTAssertTrue(status.hasNothingToPublish)
        XCTAssertFalse(status.hasPendingWork)
    }

    func testPipelineStepsOrder() {
        let pushSite = SiteProject(id: "a", name: "A", path: "/tmp/a",
                                   repositoryURL: "git@github.com:owner/repo.git",
                                   deploy: .gitPushMain)
        // Push-to-main sites verify the Actions run actually went live.
        XCTAssertEqual(SitePublishCoordinator.publishSteps(for: pushSite),
                       [.pull, .commit, .publish, .verify])
        let portal = SiteProject(id: "p", name: "P", path: "/tmp/p",
                                 repositoryURL: "git@github.com:owner/portal.git",
                                 deploy: .ghPages)
        XCTAssertEqual(SitePublishCoordinator.publishSteps(for: portal),
                       [.pull, .commit, .publish])
        // Rollback swaps the commit step for a revert.
        XCTAssertEqual(SitePublishCoordinator.rollbackSteps(for: pushSite),
                       [.pull, .revert, .publish, .verify])
    }

    func testCloudflareDeployArgsCarryProjectAndBranch() {
        let args = PagesDeployer.cloudflareDeployArgs(project: "my-site", dir: "docs")
        XCTAssertEqual(args, ["npx", "--yes", "wrangler@latest", "pages", "deploy", "docs",
                              "--project-name", "my-site", "--branch", "main",
                              "--commit-dirty=true"])
    }

    func testParseRunIDMatchesHeadSHA() {
        let json = """
        [{"databaseId":111,"headSha":"aaa"},{"databaseId":222,"headSha":"bbb"}]
        """
        XCTAssertEqual(PagesDeployer.parseRunID(json: json, headSHA: "bbb"), "222")
        XCTAssertNil(PagesDeployer.parseRunID(json: json, headSHA: "ccc"))
        XCTAssertNil(PagesDeployer.parseRunID(json: "not json", headSHA: "bbb"))
    }

    // MARK: - Integration (real git repos)

    /// A working clone synced with a local bare origin, ready for pipeline runs.
    private func makeSyncedSiteRepo(deploy: DeployMethod) throws -> (site: SiteProject, repo: URL) {
        let origin = tempDir.appendingPathComponent("origin.git")
        let work = tempDir.appendingPathComponent("work")
        try git(tempDir, ["init", "--bare", "-b", "main", "origin.git"])
        try git(tempDir, ["init", "-b", "main", "work"])
        try git(work, ["config", "user.email", "test@example.com"])
        try git(work, ["config", "user.name", "Test"])
        let readme = work.appendingPathComponent("index.html")
        try "# hello".write(to: readme, atomically: true, encoding: .utf8)
        try git(work, ["add", "-A"])
        try git(work, ["commit", "-m", "init"])
        try git(work, ["remote", "add", "origin", origin.path])
        try git(work, ["push", "-u", "origin", "main"])
        let site = SiteProject(id: "test-site", name: "Test Site", path: work.path,
                               repositoryURL: origin.path, deploy: deploy)
        return (site, work)
    }

    @discardableResult
    private func git(_ cwd: URL, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd.path] + args
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args) failed")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeHistoryStore() -> HistoryStore {
        HistoryStore(fileURL: tempDir.appendingPathComponent("history.json"))
    }

    func testCleanSyncedRepoShortCircuitsAsNothingToPublish() async throws {
        let (site, _) = try makeSyncedSiteRepo(deploy: .gitPushMain)
        let history = makeHistoryStore()
        let coordinator = SitePublishCoordinator(site: site, runner: ShellRunner(),
                                                 historyStore: history)

        let succeeded = await coordinator.run(message: "no-op")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.lastOutcome, .nothingToPublish)
        XCTAssertTrue(history.records.isEmpty, "no-op runs must not be recorded")
    }

    func testPublishPipelineCommitsPushesAndRecordsHistory() async throws {
        let (site, repo) = try makeSyncedSiteRepo(deploy: .gitPushMain)
        let history = makeHistoryStore()
        let coordinator = SitePublishCoordinator(site: site, runner: ShellRunner(),
                                                 historyStore: history)

        try "updated content".write(to: repo.appendingPathComponent("index.html"),
                                    atomically: true, encoding: .utf8)

        let succeeded = await coordinator.run(message: "update content")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(coordinator.lastOutcome, .success)
        XCTAssertTrue(coordinator.completedSteps.contains(.publish))
        XCTAssertEqual(history.records.count, 1)
        let record = try XCTUnwrap(history.records.first)
        XCTAssertTrue(record.success)
        XCTAssertEqual(record.kind, .site)
        XCTAssertEqual(record.appID, "test-site")
        XCTAssertNil(record.failureStep)
        XCTAssertFalse(record.build.isEmpty, "deployed commit hash should be recorded")

        // The bare origin received the commit: local branch no longer ahead.
        let optionalStatus = await SiteStatusService.status(at: repo.path)
        let status = try XCTUnwrap(optionalStatus, "expected git status")
        XCTAssertEqual(status.ahead, 0)
        XCTAssertTrue(status.isClean)
    }

    func testFailedPublishStepIsRetriableAndRecorded() async throws {
        // gh-pages deploy runs `npm run deploy`, which cannot succeed in a
        // bare fixture repo — pull and commit succeed, publish fails.
        let (site, repo) = try makeSyncedSiteRepo(deploy: .ghPages)
        let history = makeHistoryStore()
        let coordinator = SitePublishCoordinator(site: site, runner: ShellRunner(),
                                                 historyStore: history)

        try "portal change".write(to: repo.appendingPathComponent("index.html"),
                                  atomically: true, encoding: .utf8)

        let succeeded = await coordinator.run(message: "portal update")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(coordinator.lastOutcome, .failed("部署上线"))
        XCTAssertTrue(coordinator.canRetry)
        XCTAssertEqual(coordinator.completedSteps, [.pull, .commit])
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.failureStep, "部署上线")

        // A retry with the deploy method corrected (simulated by a fresh
        // coordinator over the same repo) pushes the committed work.
        let fixedSite = SiteProject(id: site.id, name: site.name, path: site.path,
                                    repositoryURL: site.repositoryURL, deploy: .gitPushMain)
        let retryCoordinator = SitePublishCoordinator(site: fixedSite, runner: ShellRunner(),
                                                      historyStore: history)
        let retrySucceeded = await retryCoordinator.run(message: "portal update")
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records.first?.success, true)
    }

    func testRollbackRevertsLastCommitAndRecordsRollbackTarget() async throws {
        let (site, repo) = try makeSyncedSiteRepo(deploy: .gitPushMain)
        let history = makeHistoryStore()
        let coordinator = SitePublishCoordinator(site: site, runner: ShellRunner(),
                                                 historyStore: history)

        // Publish a change first so there's something newer than "init" to revert.
        try "v2".write(to: repo.appendingPathComponent("index.html"),
                       atomically: true, encoding: .utf8)
        var succeeded = await coordinator.run(message: "v2 change")
        XCTAssertTrue(succeeded)

        let subject = await SitePublishCoordinator.lastCommitSubject(at: repo.path)
        XCTAssertEqual(subject, "v2 change")

        succeeded = await coordinator.runRollback()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(history.records.count, 2)
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.target, ReleaseRecord.siteRollbackTarget)
        XCTAssertEqual(record.targetLabel, "站点回滚")
        // The revert restored the initial content.
        let content = try String(contentsOf: repo.appendingPathComponent("index.html"),
                                 encoding: .utf8)
        XCTAssertEqual(content, "# hello")
    }
}
