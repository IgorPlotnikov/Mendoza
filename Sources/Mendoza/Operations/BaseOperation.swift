//
//  BaseOperation.swift
//  Mendoza
//
//  Created by Tomas Camin on 17/01/2019.
//

import Foundation

protocol StartingOperation: Operation {
    var didStart: (() -> Void)? { get set }
}

protocol EndingOperation: Operation {
    associatedtype OutputType
    var didEnd: ((OutputType) -> Void)? { get set }
}

protocol ThrowingOperation: Operation {
    var didThrow: ((Swift.Error) -> Void)? { get set }
}

protocol LoggedOperation: Operation {
    var logger: ExecuterLogger { get }
    var loggers: Set<ExecuterLogger> { get }
}

protocol BenchmarkedOperation: Operation {
    var startTimeInterval: TimeInterval { get }
    var endTimeInterval: TimeInterval { get }
    var poolStartTimeInterval: () -> [String: TimeInterval]  { get }
    var poolEndTimeInterval: () -> [String: TimeInterval]  { get }
}

class BaseOperation<Output: Any>: Operation, StartingOperation, EndingOperation, ThrowingOperation, LoggedOperation, BenchmarkedOperation {
    typealias OutputType = Output

    var didStart: (() -> Void)?
    var didEnd: ((Output) -> Void)?
    var didThrow: ((Swift.Error) -> Void)?

    private(set) lazy var logger = ExecuterLogger(name: "\(type(of: self))", address: "operation")
    var loggers = Set<ExecuterLogger>()

    private(set) var startTimeInterval: TimeInterval = 0.0
    private(set) var endTimeInterval: TimeInterval = 0.0
    
    private(set) var poolStartTimeInterval: () -> [String: TimeInterval] = { [:] }
    private(set) var poolEndTimeInterval: () -> [String: TimeInterval] = { [:] }
    
    private var isExecutingObserver: NSKeyValueObservation?

    private let syncQueue = DispatchQueue(label: String(describing: BaseOperation.self))

    override init() {
        super.init()

        isExecutingObserver = observe(\BaseOperation.isExecuting) { [unowned self] op, _ in
            guard !op.isCancelled else { return }

            if op.isExecuting {
                self.startTimeInterval = CFAbsoluteTimeGetCurrent()
                print("🚦 `\(op.className.components(separatedBy: ".").last ?? op.className)` did start".bold)
            } else {
                self.endTimeInterval = CFAbsoluteTimeGetCurrent()
                let delta = self.endTimeInterval - self.startTimeInterval
                print("🏁 `\(op.className.components(separatedBy: ".").last ?? op.className)` did complete in \(delta)s".bold)
            }
        }
        _ = syncQueue.sync { loggers.insert(logger) }
    }

    deinit {
        isExecutingObserver = nil
    }

    func makeConnectionPool<T>(sources: [(node: Node, value: T)]) -> ConnectionPool<T> {
        var usedLoggerAddress = [String]()
        let logger: (Node) -> ExecuterLogger = { node in
            let addressCount = usedLoggerAddress.filter { $0 == node.address }.count
            usedLoggerAddress.append(node.address)

            var loggerName = "\(type(of: self))"
            if addressCount > 0 { loggerName += "-\(addressCount + 1)" }

            return ExecuterLogger(name: loggerName, address: node.address)
        }

        let poolSources = sources.map { ConnectionPool<T>.Source(node: $0.node, value: $0.value, logger: logger($0.node)) }
        let pool = ConnectionPool(sources: poolSources)

        let poolLoggers = Set(poolSources.compactMap(\.logger))
        syncQueue.sync { loggers = loggers.union(poolLoggers) }
        
        poolStartTimeInterval = { pool.startIntervals }
        poolEndTimeInterval = { pool.endIntervals }
        
        return pool
    }

    func makeConnectionPool(sources: [Node]) -> ConnectionPool<Void> {
        makeConnectionPool(sources: sources.map { (node: $0, value: ()) })
    }

    func makeLocalExecuter(currentDirectoryPath: String? = nil) -> LocalExecuter {
        let address = "localhost"
        var loggerName = "\(type(of: self))"
        let addressCount = syncQueue.sync { loggers.filter { $0.name == loggerName && $0.address == address }.count }

        if addressCount > 0 { loggerName += "-\(addressCount + 1)" }

        let logger = ExecuterLogger(name: loggerName, address: address)
        let executerLogger = syncQueue.sync { loggers.update(with: logger) }
        return LocalExecuter(currentDirectoryPath: currentDirectoryPath, logger: executerLogger ?? logger)
    }

    func makeRemoteExecuter(node: Node, currentDirectoryPath: String? = nil) -> RemoteExecuter {
        let address = node.address
        let addressCount = syncQueue.sync { loggers.filter { $0.address == address }.count }

        var loggerName = "\(type(of: self))"
        if addressCount > 0 { loggerName += "-\(addressCount + 1)" }

        let logger = ExecuterLogger(name: loggerName, address: address)
        let executerLogger = syncQueue.sync { loggers.update(with: logger) }
        return RemoteExecuter(node: node, currentDirectoryPath: currentDirectoryPath, logger: executerLogger ?? logger)
    }
}

enum Path: String, CaseIterable {
    case base, build, testBundle, logs, results, temp

    var rawValue: String {
        switch self {
        case .base: return Environment.temporaryBasePath
        case .build: return Path.base.rawValue.appending("/build")
        case .testBundle: return Path.build.rawValue.appending("/Build/Products")
        case .logs: return Path.base.rawValue.appending("/logs")
        case .results: return Path.base.rawValue.appending("/results")
        case .temp: return Path.base.rawValue.appending("/tmp")
        }
    }

    var url: URL {
        URL(fileURLWithPath: rawValue)
    }
}
