//
//  TearDownOperation.swift
//  Mendoza
//
//  Created by Tomas Camin on 17/01/2019.
//

import Foundation

class TearDownOperation: BaseOperation<Void> {
    var testSessionResult: TestSessionResult?

    private lazy var pool: ConnectionPool = {
        makeConnectionPool(sources: configuration.nodes)
    }()

    private let configuration: Configuration

    private let timestamp: String
    private let mergeResults: Bool
    private let git: GitStatus?
    private lazy var executer: Executer? = {
        let destinationNode = configuration.resultDestination.node

        let logger = ExecuterLogger(name: "\(type(of: self))", address: destinationNode.address)
        return try? destinationNode.makeExecuter(logger: logger)
    }()
    private let plugin: TearDownPlugin


    init(configuration: Configuration, git: GitStatus?, timestamp: String, mergeResults: Bool, plugin: TearDownPlugin) {
        self.configuration = configuration
        self.git = git
        self.timestamp = timestamp
        self.mergeResults = mergeResults
        self.plugin = plugin
        super.init()
        loggers.insert(plugin.logger)
    }

    override func main() {
        guard !isCancelled else { return }

        do {
            didStart?()

            guard let executer = executer else { fatalError("💣 Failed making executer") }

            try writeHtmlRepeatedTestResultSummary(executer: executer)
            try writeJsonRepeatedTestResultSummary(executer: executer)
            try writeHtmlTestResultSummary(executer: executer)
            try writeJsonTestResultSummary(executer: executer)
            try writeJsonTestSuiteResult(executer: executer)
            try writeHtmlExecutionGraph(executer: executer)
            try writeGitInfo(executer: executer)
            let infoPlistPath: String
            if mergeResults {
                infoPlistPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.resultFoldername)/\(Environment.xcresultFilename)/Info.plist"
            } else {
                infoPlistPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.resultFoldername)/\(Environment.xcresultFirstUnmergedFilename)/Info.plist"
            }
            try writeGitInfoInResultBundleInfoPlist(executer: executer, infoPlistPath: infoPlistPath)

            try pool.execute { executer, source in
                if AddressType(node: source.node) == .remote {
                    _ = try? executer.execute("rm -rf '\(Path.base.rawValue)/*'")
                }
            }

            if plugin.isInstalled {
                guard let testSessionResult = testSessionResult else { fatalError("💣 Required fields not set") }
                _ = try plugin.run(input: testSessionResult)
            }

            didEnd?(())
        } catch {
            didThrow?(error)
        }
    }

    override func cancel() {
        if isExecuting {
            pool.terminate()
        }
        super.cancel()
    }

    private func writeHtmlRepeatedTestResultSummary(executer: Executer) throws {
        guard var repeatedTestCases = testSessionResult?.retriedTests else { return }
        repeatedTestCases = repeatedTestCases.sorted(by: { $0.description < $1.description })

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.htmlRepeatedTestSummaryFilename)"

        var content = "<h2>Result - repeated tests</h2>\n"

        if repeatedTestCases.count > 0 {
            for testCase in repeatedTestCases {
                content += "<p class='failed'>\(testCase)</p>\n"
            }
        } else {
            content += "<p>No repeated tests</p>\n"
        }

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).html")

        guard let contentData = TestCaseResult.html(content: content).data(using: .utf8) else {
            throw Error("Failed writing html repeated test summary data")
        }

        try contentData.write(to: tempUrl)
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeJsonRepeatedTestResultSummary(executer: Executer) throws {
        guard var repeatedTestCases = testSessionResult?.retriedTests else { return }
        repeatedTestCases = repeatedTestCases.sorted(by: { $0.description < $1.description })

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.jsonRepeatedTestSummaryFilename)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let contentData = try? encoder.encode(repeatedTestCases) else {
            throw Error("Failed writing json repeated test summary data")
        }

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).json")

        try contentData.write(to: tempUrl)
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeHtmlTestResultSummary(executer: Executer) throws {
        guard let testSessionResult = testSessionResult else { return }

        var testCaseResults = testSessionResult.passedTests + testSessionResult.failedTests
        testCaseResults = testCaseResults.sorted(by: { $0.description < $1.description })

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.htmlTestSummaryFilename)"

        var content = "<h2>Result</h2>\n"

        for testCase in testCaseResults {
            switch testCase.status {
            case .passed:
                content += "<p class='passed'>✓ \(testCase)</p>\n"
            case .failed:
                content += "<p class='failed'>𝘅 \(testCase)</p>\n"
            }
        }

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).html")

        guard let contentData = TestCaseResult.html(content: content).data(using: .utf8) else {
            throw Error("Failed writing html test summary data")
        }

        try contentData.write(to: tempUrl)
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeJsonTestResultSummary(executer: Executer) throws {
        guard let testSessionResult = testSessionResult else { return }

        var testCaseResults = testSessionResult.passedTests + testSessionResult.failedTests
        testCaseResults = testCaseResults.sorted(by: { $0.description < $1.description })

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.jsonTestSummaryFilename)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let contentData = try? encoder.encode(testCaseResults.sorted(by: { $0.description < $1.description })) else {
            throw Error("Failed writing json test summary data")
        }

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).json")

        try contentData.write(to: tempUrl)
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeJsonTestSuiteResult(executer: Executer) throws {
        guard let testSessionResult = testSessionResult else { return }

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.jsonSuiteResultFilename)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(testSessionResult)

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: tempUrl)

        _ = try executer.execute("mkdir -p '\(destinationPath)'")
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeHtmlExecutionGraph(executer: Executer) throws {
        guard let testSessionResult = testSessionResult else { return }

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.htmlExecutionGraphFilename)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(testSessionResult)

        let suiteDetailJson = String(decoding: data, as: UTF8.self)

        let executionGraph = ExecutionGraph.template.replacingOccurrences(of: "$$TEST_DETAIL_JSON", with: suiteDetailJson)

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).html")

        try Data(executionGraph.utf8).write(to: tempUrl)

        _ = try executer.execute("mkdir -p '\(destinationPath)'")
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeGitInfo(executer: Executer) throws {
        guard let git = git else { return }

        let destinationPath = "\(configuration.resultDestination.path)/\(timestamp)/\(Environment.jsonGitSummaryFilename)"

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let contentData = try? encoder.encode(git) else {
            throw Error("Failed writing json git data")
        }

        let tempUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).json")

        try contentData.write(to: tempUrl)
        try executer.upload(localUrl: tempUrl, remotePath: destinationPath)
    }

    private func writeGitInfoInResultBundleInfoPlist(executer: Executer, infoPlistPath: String) throws {
        guard let git = git else { return }

        let uniqueUrl = Path.temp.url.appendingPathComponent("\(UUID().uuidString).plist")
        try executer.download(remotePath: infoPlistPath, localUrl: uniqueUrl)

        guard let data = try? Data(contentsOf: uniqueUrl) else { return }

        var infoPlist = try PropertyListDecoder().decode([String: AnyCodable].self, from: data)

        infoPlist["branchName"] = AnyCodable(git.branch)
        infoPlist["commitMessage"] = AnyCodable(git.commitMessage)
        infoPlist["commitHash"] = AnyCodable(git.commitHash)

        guard let contentData = try? PropertyListEncoder().encode(infoPlist) else {
            throw Error("Failed writing json git data to xcresult bundle Info.plit")
        }

        try contentData.write(to: uniqueUrl)
        try executer.upload(localUrl: uniqueUrl, remotePath: infoPlistPath)
    }
}

private extension TestCaseResult {
    static func html(content: String) -> String {
        let contentMarker = "{{ content }}"
        return
            """
            <html>
            <meta charset="UTF-8">
            <head>
                <style>
                    body {
                        font-family: Menlo, Courier;
                        font-weight: normal;
                        color: rgb(30, 30, 30);
                        font-size: 80%;
                        margin-left: 20px;
                    }
                    p {
                        font-weight: lighter;
                    }
                    p.passed {
                        color: rgb(20,149,61);
                    }
                    p.failed {
                        color: rgb(223,26,33);
                    }
                    summary::-webkit-details-marker {
                        display: none;
                    }
                </style>
            </head>
            <body>
            \(contentMarker)
            </body>
            </html>
            """.replacingOccurrences(of: contentMarker, with: content)
    }
}
